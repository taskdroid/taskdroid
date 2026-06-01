import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/widgets/tag_input.dart';
import 'package:taskdroid/widgets/task_selector.dart';
import 'package:taskdroid/widgets/uda_editor.dart';

enum TaskEditorMode { normal, instance, series }

Future<TaskEditorResult?> showTaskEditorSheet(
  BuildContext context, {
  TaskView? originalTask,
  TaskEditorMode mode = TaskEditorMode.normal,
  TaskEditorInitialValues? initialValues,
}) {
  return showModalBottomSheet<TaskEditorResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.92,
      child: TaskEditor(
        originalTask: originalTask,
        mode: mode,
        initialValues: initialValues,
      ),
    ),
  );
}

class TaskEditorInitialValues {
  final String? project;
  final String? priority;
  final List<String>? tags;

  const TaskEditorInitialValues({this.project, this.priority, this.tags});
}

class TaskEditorResult {
  final String description;
  final String? project;
  final String? priority;
  final List<String> tags;
  final DateTime? due;
  final DateTime? wait;
  final DateTime? scheduled;
  final DateTime? until;
  final String? recurrence;
  final List<String> dependencies;
  final List<UdaPair> udas;

  TaskEditorResult({
    required this.description,
    required this.project,
    required this.priority,
    required this.tags,
    required this.due,
    required this.wait,
    required this.scheduled,
    required this.until,
    required this.recurrence,
    required this.dependencies,
    required this.udas,
  });
}

class TaskEditor extends StatefulWidget {
  final TaskView? originalTask;
  final TaskEditorMode mode;
  final TaskEditorInitialValues? initialValues;

  const TaskEditor({
    super.key,
    this.originalTask,
    this.mode = TaskEditorMode.normal,
    this.initialValues,
  });

  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  late TabController _tabController;

  late final TextEditingController _descriptionController;
  late final TextEditingController _dueDateController;
  late final TextEditingController _waitDateController;
  late final TextEditingController _scheduledDateController;
  late final TextEditingController _untilDateController;
  late final TextEditingController _durationController;
  late final TextEditingController _recurrenceController;

  String _project = '';

  String? _selectedPriority;
  List<String> _selectedTags = [];
  Set<String> _currentDependencies = {};
  List<UdaPair> _currentUdas = [];

  DateTime? _selectedDueDate;
  DateTime? _selectedWaitDate;
  DateTime? _selectedScheduledDate;
  DateTime? _selectedUntilDate;
  String _recurrence = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    final t = widget.originalTask;

    _descriptionController = TextEditingController(text: t?.description ?? '');
    _selectedPriority = t?.priority ?? 'X';
    _selectedTags = t != null ? List.from(t.tags) : [];
    _currentDependencies = t != null ? Set.from(t.depends) : {};

    _project = t?.project ?? '';

    String initialDuration = '60';
    if (t != null) {
      final allUdas = t.udas
          .map((u) => UdaPair(key: u.key, value: u.value))
          .toList();
      final durIndex = allUdas.indexWhere((u) => u.key == 'duration');

      if (durIndex != -1) {
        initialDuration = allUdas[durIndex].value;
        allUdas.removeAt(durIndex);
      }
      _currentUdas = allUdas;
      _recurrence = t.recurrence ?? '';
    }

    _durationController = TextEditingController(text: initialDuration);
    _recurrenceController = TextEditingController(text: _recurrence);

    // apply write query defaults for new tasks
    if (widget.initialValues != null && t == null) {
      final iv = widget.initialValues!;
      if (iv.project != null && _project.isEmpty) _project = iv.project!;
      if (iv.priority != null && _selectedPriority == 'X') {
        final normalized = iv.priority!.toUpperCase();
        if (const {'H', 'M', 'L'}.contains(normalized)) {
          _selectedPriority = normalized;
        }
      }
      if (iv.tags != null) {
        _selectedTags = {..._selectedTags, ...iv.tags!}.toList();
      }
    }

    _dueDateController = _initDateController(
      t?.due,
      (d) => _selectedDueDate = d,
    );
    _waitDateController = _initDateController(
      t?.wait,
      (d) => _selectedWaitDate = d,
    );
    _scheduledDateController = _initDateController(
      t?.scheduled,
      (d) => _selectedScheduledDate = d,
    );
    _untilDateController = _initDateController(
      t?.until,
      (d) => _selectedUntilDate = d,
    );
  }

  TextEditingController _initDateController(
    String? isoDate,
    Function(DateTime) onSet,
  ) {
    if (isoDate != null) {
      try {
        final d = DateTime.parse(isoDate).toLocal();
        onSet(d);
        return TextEditingController(text: _formatDate(d));
      } catch (_) {}
    }
    return TextEditingController();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _descriptionController.dispose();
    _dueDateController.dispose();
    _waitDateController.dispose();
    _scheduledDateController.dispose();
    _untilDateController.dispose();
    _durationController.dispose();
    _recurrenceController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime date) {
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.day} ${monthNames[date.month - 1]} ${date.year} $hour:$minute';
  }

  Future<void> _pickDateTime(
    DateTime? current,
    Function(DateTime?) onPicked,
  ) async {
    final now = DateTime.now();
    final initialDate = current ?? now;

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (pickedDate == null || !mounted) return;

    final initialTime = TimeOfDay.fromDateTime(initialDate);
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: initialTime,
    );

    if (!mounted) return;
    final time = pickedTime ?? const TimeOfDay(hour: 0, minute: 0);

    onPicked(
      DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        time.hour,
        time.minute,
      ),
    );
  }

  void _addDependency() async {
    final excluded = <String>[];
    if (widget.originalTask != null) excluded.add(widget.originalTask!.uuid);
    excluded.addAll(_currentDependencies);

    final selectedUuid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.8,
        child: TaskSelector(excludedUuids: excluded),
      ),
    );

    if (selectedUuid != null && mounted) {
      setState(() => _currentDependencies.add(selectedUuid));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final taskState = context.read<TaskState>();
    final isEditing = widget.originalTask != null;
    final title = switch (widget.mode) {
      TaskEditorMode.instance => 'Edit Instance',
      TaskEditorMode.series => 'Edit Series',
      TaskEditorMode.normal => isEditing ? 'Edit Task' : 'New Task',
    };

    return Column(
      children: [
        // Drag Handle
        Container(
          width: 32,
          height: 4,
          margin: const EdgeInsets.only(top: 12, bottom: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),

        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
          child: Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (widget.mode != TaskEditorMode.normal)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: _buildModeBanner(theme),
          ),

        // Tabs
        TabBar(
          controller: _tabController,
          labelColor: theme.colorScheme.primary,
          unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: theme.colorScheme.outline.withValues(alpha: 0.1),
          tabs: const [
            Tab(text: 'General', icon: Icon(Icons.article_outlined)),
            Tab(text: 'Advanced', icon: Icon(Icons.settings_suggest_outlined)),
          ],
        ),

        // Body
        Expanded(
          child: Form(
            key: _formKey,
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildGeneralTab(
                  theme,
                  taskState.allProjects,
                  taskState.allTags,
                ),
                _buildAdvancedTab(theme),
              ],
            ),
          ),
        ),

        // Footer Actions
        Container(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _saveTask,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  isEditing ? 'Save Changes' : 'Create',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildModeBanner(ThemeData theme) {
    final isSeries = widget.mode == TaskEditorMode.series;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isSeries
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
            : theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color:
              (isSeries
                      ? theme.colorScheme.primary
                      : theme.colorScheme.secondary)
                  .withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isSeries ? Icons.all_inclusive : Icons.event_repeat,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isSeries
                  ? 'Changes apply to the series template and pending generated instances. Completed history stays unchanged.'
                  : 'You are editing one occurrence only. The recurring series will continue.',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  void _saveTask() {
    if (_formKey.currentState?.validate() != true) return;

    final finalUdas = _currentUdas.where((u) => u.key != 'duration').toList();

    final durationVal = _durationController.text.trim();
    if (durationVal.isNotEmpty) {
      finalUdas.add(UdaPair(key: 'duration', value: durationVal));
    }

    final recurrenceVal = _recurrenceController.text.trim();

    final project = _project.trim();

    final result = TaskEditorResult(
      description: _descriptionController.text.trim(),
      project: project.isEmpty ? null : project,
      priority: _selectedPriority == 'X' ? null : _selectedPriority,
      tags: _selectedTags,
      due: _selectedDueDate,
      wait: _selectedWaitDate,
      scheduled: _selectedScheduledDate,
      until: _selectedUntilDate,
      recurrence: recurrenceVal.isEmpty ? null : recurrenceVal,
      dependencies: _currentDependencies.toList(),
      udas: finalUdas,
    );

    Navigator.pop<TaskEditorResult>(context, result);
  }

  Widget _buildGeneralTab(
    ThemeData theme,
    Set<String> allProjects,
    Set<String> allTags,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _descriptionController,
            autofocus: widget.originalTask == null,
            decoration: const InputDecoration(
              labelText: 'Task Description *',
              prefixIcon: Icon(Icons.description_outlined),
            ),
            validator: (v) => v!.trim().isEmpty ? 'Required field' : null,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Autocomplete<String>(
                  initialValue: TextEditingValue(text: _project),
                  optionsBuilder: (textEditingValue) {
                    final filter = textEditingValue.text.toLowerCase();
                    if (filter.isEmpty) {
                      return allProjects;
                    }
                    return allProjects.where(
                      (option) => option.toLowerCase().contains(filter),
                    );
                  },
                  onSelected: (selection) {
                    setState(() {
                      _project = selection;
                    });
                  },
                  fieldViewBuilder:
                      (context, controller, focusNode, onFieldSubmitted) {
                        // Sync controller with _project if they differ
                        if (controller.text != _project) {
                          controller.text = _project;
                        }

                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          decoration: const InputDecoration(
                            labelText: 'Project',
                            prefixIcon: Icon(Icons.folder_outlined),
                          ),
                          onChanged: (value) {
                            setState(() {
                              _project = value;
                            });
                          },
                        );
                      },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 1,
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedPriority,
                  decoration: const InputDecoration(
                    labelText: 'Priority',
                    prefixIcon: Icon(Icons.flag_outlined),
                  ),
                  items: ['X', 'H', 'M', 'L']
                      .map(
                        (p) => DropdownMenuItem(
                          value: p,
                          child: Text(p == 'X' ? 'None' : p),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _selectedPriority = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          TagInput(
            selectedTags: _selectedTags,
            availableTags: allTags,
            onChanged: (newTags) => setState(() => _selectedTags = newTags),
          ),
          const SizedBox(height: 32),
          Text(
            'Timeline',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),

          _buildDateField(
            label: 'Due Date',
            icon: Icons.event,
            controller: _dueDateController,
            onTap: () => _pickDateTime(_selectedDueDate, (d) {
              setState(() {
                _selectedDueDate = d;
                _dueDateController.text = _formatDate(d!);
              });
            }),
            onClear: () => setState(() {
              _selectedDueDate = null;
              _dueDateController.clear();
            }),
          ),
          const SizedBox(height: 12),

          _buildDateField(
            label: 'Wait Until',
            icon: Icons.hourglass_empty,
            controller: _waitDateController,
            onTap: () => _pickDateTime(_selectedWaitDate, (d) {
              setState(() {
                _selectedWaitDate = d;
                _waitDateController.text = _formatDate(d!);
              });
            }),
            onClear: () => setState(() {
              _selectedWaitDate = null;
              _waitDateController.clear();
            }),
          ),
          const SizedBox(height: 12),

          _buildDateField(
            label: 'Scheduled',
            icon: Icons.schedule,
            controller: _scheduledDateController,
            onTap: () => _pickDateTime(_selectedScheduledDate, (d) {
              setState(() {
                _selectedScheduledDate = d;
                _scheduledDateController.text = _formatDate(d!);
              });
            }),
            onClear: () => setState(() {
              _selectedScheduledDate = null;
              _scheduledDateController.clear();
            }),
          ),

          SizedBox(
            height: MediaQuery.of(context).viewInsets.bottom > 0 ? 0 : 40,
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Calendar Integration',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _durationController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Duration (minutes)',
              prefixIcon: Icon(Icons.timer_outlined),
              hintText: 'Default: 60',
            ),
          ),
          const SizedBox(height: 32),

          Text(
            'Recurrence',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          if (widget.mode == TaskEditorMode.instance) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.2),
                ),
              ),
              child: Text(
                'Repeat settings belong to the series. Choose "Edit series" to change the rule or end date.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ] else ...[
            TextFormField(
              controller: _recurrenceController,
              decoration: const InputDecoration(
                labelText: 'Repeat Rule',
                prefixIcon: Icon(Icons.loop),
                hintText: 'e.g. daily, weekly, monthly',
                helperText:
                    'Also supports shorthand/ISO forms: 5d, 2w, 3mo, P1M, PT6H',
              ),
              onChanged: (value) => setState(() => _recurrence = value.trim()),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  [
                        'daily',
                        'weekly',
                        'biweekly',
                        '5d',
                        '2w',
                        '3mo',
                        'monthly',
                        'quarterly',
                        'yearly',
                        'weekdays',
                      ]
                      .map(
                        (preset) => ActionChip(
                          label: Text(preset),
                          backgroundColor: _recurrence == preset
                              ? theme.colorScheme.primaryContainer
                              : null,
                          side: BorderSide(
                            color: _recurrence == preset
                                ? Colors.transparent
                                : theme.colorScheme.outline.withValues(
                                    alpha: 0.3,
                                  ),
                          ),
                          onPressed: () {
                            setState(() {
                              _recurrence = preset;
                              _recurrenceController.text = preset;
                            });
                          },
                        ),
                      )
                      .toList(),
            ),
            const SizedBox(height: 16),

            _buildDateField(
              label: 'Repeat Until',
              icon: Icons.event_busy,
              controller: _untilDateController,
              onTap: () => _pickDateTime(_selectedUntilDate, (d) {
                setState(() {
                  _selectedUntilDate = d;
                  _untilDateController.text = _formatDate(d!);
                });
              }),
              onClear: () => setState(() {
                _selectedUntilDate = null;
                _untilDateController.clear();
              }),
            ),
          ],
          const SizedBox(height: 32),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Blocked By',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              TextButton.icon(
                onPressed: _addDependency,
                icon: const Icon(Icons.add_link, size: 18),
                label: const Text('Add Task'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_currentDependencies.isEmpty)
            Text(
              'No dependencies blocking this task.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ..._currentDependencies.map((uuid) {
            return Consumer<TaskState>(
              builder: (context, state, _) {
                final name = state.getTaskDescription(uuid);
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    leading: Icon(
                      Icons.subdirectory_arrow_right,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.remove_circle_outline,
                        color: theme.colorScheme.error,
                      ),
                      onPressed: () =>
                          setState(() => _currentDependencies.remove(uuid)),
                    ),
                  ),
                );
              },
            );
          }),
          const SizedBox(height: 32),

          UdaEditor(
            initialUdas: _currentUdas,
            onChanged: (newList) => _currentUdas = newList,
          ),
          SizedBox(
            height: MediaQuery.of(context).viewInsets.bottom > 0 ? 0 : 40,
          ),
        ],
      ),
    );
  }

  Widget _buildDateField({
    required String label,
    required IconData icon,
    required TextEditingController controller,
    required VoidCallback onTap,
    required VoidCallback onClear,
  }) {
    return TextFormField(
      controller: controller,
      readOnly: true,
      onTap: onTap,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixIcon: controller.text.isNotEmpty
            ? IconButton(icon: const Icon(Icons.clear), onPressed: onClear)
            : null,
      ),
    );
  }
}
