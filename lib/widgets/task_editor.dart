import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/models/task_virtual_flags.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/theme/tokens.dart';
import 'package:taskdroid/widgets/common/app_attribute_chip.dart';
import 'package:taskdroid/widgets/common/app_collapsible_section.dart';
import 'package:taskdroid/widgets/common/app_section_card.dart';
import 'package:taskdroid/widgets/common/app_sheet.dart';
import 'package:taskdroid/widgets/common/app_value_row.dart';
import 'package:taskdroid/widgets/tag_input.dart';
import 'package:taskdroid/widgets/task_selector.dart';
import 'package:taskdroid/widgets/uda_editor.dart';

/// Width reserved for the priority chip so its box never moves when a priority
/// is picked or cleared.
const double _priorityChipWidth = 136;

enum TaskEditorMode { normal, instance, series }

Future<TaskEditorResult?> showTaskEditorSheet(
  BuildContext context, {
  TaskView? originalTask,
  TaskEditorMode mode = TaskEditorMode.normal,
  TaskEditorInitialValues? initialValues,
}) {
  return showAppSheet<TaskEditorResult>(
    context,
    scrollControlled: true,
    heightFactor: 0.92,
    builder: (ctx) => TaskEditor(
      originalTask: originalTask,
      mode: mode,
      initialValues: initialValues,
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

class _TaskEditorState extends State<TaskEditor> {
  late final TextEditingController _descriptionController;
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

    final t = widget.originalTask;

    _descriptionController = TextEditingController(text: t?.description ?? '');
    _selectedPriority = t?.priority ?? 'X';
    _selectedTags = t != null ? userTags(t.tags) : [];
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
        _selectedTags = {..._selectedTags, ...userTags(iv.tags!)}.toList();
      }
    }

    _selectedDueDate = _parseDate(t?.due);
    _selectedWaitDate = _parseDate(t?.wait);
    _selectedScheduledDate = _parseDate(t?.scheduled);
    _selectedUntilDate = _parseDate(t?.until);
  }

  DateTime? _parseDate(String? isoDate) {
    if (isoDate == null) return null;
    try {
      return DateTime.parse(isoDate).toLocal();
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
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

    final selectedUuid = await showAppSheet<String>(
      context,
      scrollControlled: true,
      heightFactor: 0.8,
      builder: (context) => TaskSelector(excludedUuids: excluded),
    );

    if (selectedUuid != null && mounted) {
      setState(() => _currentDependencies.add(selectedUuid));
    }
  }

  Future<void> _pickProject(Set<String> allProjects) async {
    final picked = await showAppSheet<String>(
      context,
      scrollControlled: true,
      heightFactor: 0.7,
      builder: (sheetContext) =>
          _ProjectPickerSheet(projects: allProjects, selected: _project),
    );

    if (picked != null && mounted) setState(() => _project = picked);
  }

  Future<void> _pickPriority() async {
    const options = [
      ('X', 'None'),
      ('L', 'Low'),
      ('M', 'Medium'),
      ('H', 'High'),
    ];

    final picked = await showAppSheet<String>(
      context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppSheetHeader(title: 'Priority'),
          for (final (code, label) in options)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpace.lg,
              ),
              leading: const Icon(Icons.flag_outlined),
              title: Text(label),
              trailing: _selectedPriority == code
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(context, code),
            ),
          const SizedBox(height: AppSpace.lg),
        ],
      ),
    );

    if (picked != null && mounted) {
      setState(() => _selectedPriority = picked);
    }
  }

  Future<void> _pickTags(Set<String> availableTags) async {
    var tags = List<String>.from(_selectedTags);

    final picked = await showAppSheet<List<String>>(
      context,
      scrollControlled: true,
      heightFactor: 0.85,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Column(
          children: [
            AppSheetActionBar(
              title: 'Tags',
              onCancel: () => Navigator.pop(context),
              actionLabel: 'Done',
              onAction: () => Navigator.pop(context, tags),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                child: TagInput(
                  selectedTags: tags,
                  availableTags: availableTags,
                  onChanged: (newTags) => setSheetState(() => tags = newTags),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (picked != null && mounted) {
      setState(() => _selectedTags = picked);
    }
  }

  void _saveTask() {
    if (_descriptionController.text.trim().isEmpty) return;

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

  String? get _priorityLabel => switch (_selectedPriority) {
    'H' => 'High',
    'M' => 'Medium',
    'L' => 'Low',
    _ => null,
  };

  String? get _tagsLabel {
    if (_selectedTags.isEmpty) return null;
    return _selectedTags.join(' · ');
  }

  bool get _advancedInitiallyExpanded =>
      widget.originalTask != null &&
      (_currentUdas.isNotEmpty ||
          _recurrence.isNotEmpty ||
          _selectedUntilDate != null ||
          _currentDependencies.isNotEmpty);

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
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _descriptionController,
          builder: (context, value, _) => AppSheetActionBar(
            title: title,
            onCancel: () => Navigator.pop(context),
            actionLabel: isEditing ? 'Save' : 'Create',
            onAction: value.text.trim().isEmpty ? null : _saveTask,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.md,
              AppSpace.lg,
              AppSpace.xl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.mode != TaskEditorMode.normal) ...[
                  _buildModeBanner(theme),
                  const SizedBox(height: AppSpace.lg),
                ],
                TextField(
                  controller: _descriptionController,
                  autofocus: !isEditing,
                  maxLines: null,
                  minLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  // Done on the keyboard only finishes typing the description;
                  // the task is created from the action bar.
                  textInputAction: TextInputAction.done,
                  style: theme.textTheme.titleLarge,
                  decoration: const InputDecoration(
                    hintText: 'What needs doing?',
                    isCollapsed: true,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                  ),
                ),
                const SizedBox(height: AppSpace.lg),
                _buildAttributeChips(taskState),
                const SizedBox(height: AppSpace.xl),
                _buildTimeline(theme),
                const SizedBox(height: AppSpace.xl),
                AppCollapsibleSection(
                  title: 'Advanced',
                  initiallyExpanded: _advancedInitiallyExpanded,
                  child: _buildAdvanced(theme),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModeBanner(ThemeData theme) {
    final isSeries = widget.mode == TaskEditorMode.series;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: isSeries
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
            : theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.input),
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
          const SizedBox(width: AppSpace.md),
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

  Widget _buildAttributeChips(TaskState taskState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: AppAttributeChip(
                icon: Icons.folder_outlined,
                label: 'Project',
                value: _project.isEmpty ? null : _project,
                onTap: () => _pickProject(taskState.allProjects),
                onClear: () => setState(() => _project = ''),
                expand: true,
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            // Fixed width so picking a priority never resizes or shifts the row.
            SizedBox(
              width: _priorityChipWidth,
              child: AppAttributeChip(
                icon: Icons.flag_outlined,
                label: 'Priority',
                value: _priorityLabel,
                onTap: _pickPriority,
                onClear: () => setState(() => _selectedPriority = 'X'),
                expand: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        // Tags get the full row and up to two lines before ellipsizing.
        AppAttributeChip(
          icon: Icons.local_offer_outlined,
          label: 'Tags',
          value: _tagsLabel,
          onTap: () => _pickTags(taskState.allTags),
          onClear: () => setState(() => _selectedTags = []),
          expand: true,
          maxLines: 2,
        ),
      ],
    );
  }

  Widget _buildSectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.titleToCard),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildTimeline(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionTitle(theme, 'Timeline'),
        AppSectionCard.rows([
          AppValueRow(
            label: 'Due',
            value: _selectedDueDate == null
                ? null
                : _formatDate(_selectedDueDate!),
            onTap: () => _pickDateTime(
              _selectedDueDate,
              (d) => setState(() => _selectedDueDate = d),
            ),
            onClear: () => setState(() => _selectedDueDate = null),
          ),
          AppValueRow(
            label: 'Scheduled',
            value: _selectedScheduledDate == null
                ? null
                : _formatDate(_selectedScheduledDate!),
            onTap: () => _pickDateTime(
              _selectedScheduledDate,
              (d) => setState(() => _selectedScheduledDate = d),
            ),
            onClear: () => setState(() => _selectedScheduledDate = null),
          ),
          AppValueRow(
            label: 'Wait',
            value: _selectedWaitDate == null
                ? null
                : _formatDate(_selectedWaitDate!),
            onTap: () => _pickDateTime(
              _selectedWaitDate,
              (d) => setState(() => _selectedWaitDate = d),
            ),
            onClear: () => setState(() => _selectedWaitDate = null),
          ),
        ]),
      ],
    );
  }

  Widget _buildAdvanced(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _durationController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Duration (minutes)',
              hintText: 'Default: 60',
            ),
          ),
          const SizedBox(height: AppSpace.xl),
          if (widget.mode == TaskEditorMode.instance)
            AppSectionCard(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Text(
                'Repeat settings belong to the series. Choose "Edit series" to change the rule or end date.',
                style: theme.textTheme.bodyMedium,
              ),
            )
          else ...[
            TextFormField(
              controller: _recurrenceController,
              decoration: const InputDecoration(
                labelText: 'Repeat Rule',
                hintText: 'e.g. daily, weekly, monthly',
                helperText:
                    'Also supports shorthand/ISO forms: 5d, 2w, 3mo, P1M, PT6H',
              ),
              onChanged: (value) => setState(() => _recurrence = value.trim()),
            ),
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
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
            const SizedBox(height: AppSpace.lg),
            AppSectionCard.rows([
              AppValueRow(
                label: 'Until',
                value: _selectedUntilDate == null
                    ? null
                    : _formatDate(_selectedUntilDate!),
                onTap: () => _pickDateTime(
                  _selectedUntilDate,
                  (d) => setState(() => _selectedUntilDate = d),
                ),
                onClear: () => setState(() => _selectedUntilDate = null),
              ),
            ]),
          ],
          const SizedBox(height: AppSpace.xl),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Blocked by',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              TextButton.icon(
                onPressed: _addDependency,
                icon: const Icon(Icons.add_link, size: 18),
                label: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (_currentDependencies.isEmpty)
            Text(
              'No dependencies blocking this task.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            )
          else
            AppSectionCard.rows([
              for (final uuid in _currentDependencies)
                Consumer<TaskState>(
                  builder: (context, state, _) => AppValueRow(
                    icon: Icons.subdirectory_arrow_right,
                    label: state.getTaskDescription(uuid),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Remove',
                      onPressed: () =>
                          setState(() => _currentDependencies.remove(uuid)),
                    ),
                  ),
                ),
            ]),
          const SizedBox(height: AppSpace.xl),
          UdaEditor(
            initialUdas: _currentUdas,
            onChanged: (newList) => _currentUdas = newList,
          ),
        ],
      ),
    );
  }
}

/// Project picker for the task editor. Owns its search field's controller so
/// the controller outlives the sheet's exit animation: disposing it as soon as
/// `showAppSheet` returns tears it down under the still-visible sheet.
class _ProjectPickerSheet extends StatefulWidget {
  const _ProjectPickerSheet({required this.projects, required this.selected});

  final Set<String> projects;
  final String selected;

  @override
  State<_ProjectPickerSheet> createState() => _ProjectPickerSheetState();
}

class _ProjectPickerSheetState extends State<_ProjectPickerSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.selected);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.trim();
    final matches =
        widget.projects
            .where((p) => p.toLowerCase().contains(query.toLowerCase()))
            .toList()
          ..sort();
    final canUseTyped =
        query.isNotEmpty &&
        !widget.projects.any((p) => p.toLowerCase() == query.toLowerCase());

    return Column(
      children: [
        const AppSheetHeader(title: 'Project'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          child: TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Search or type a new project',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Expanded(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
            children: [
              if (canUseTyped)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.lg,
                  ),
                  leading: const Icon(Icons.add),
                  title: Text('Use "$query"'),
                  onTap: () => Navigator.pop(context, query),
                ),
              for (final project in matches)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.lg,
                  ),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(project),
                  trailing: project == widget.selected
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(context, project),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
