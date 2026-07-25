import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/profile_state.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/models/profile.dart';
import 'package:taskdroid/services/profile_storage.dart';
import 'package:taskdroid/services/taskrc_config_service.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/widgets/app_drawer.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

class CredentialsPage extends StatefulWidget {
  const CredentialsPage({super.key});

  @override
  State<CredentialsPage> createState() => _CredentialsPageState();
}

class _CredentialsPageState extends State<CredentialsPage> {
  final _nameController = TextEditingController();
  final _uuidController = TextEditingController();
  final _secretController = TextEditingController();
  final _serverUrlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  bool _isTesting = false;
  String? _testResult;
  bool _isEditing = false;
  String? _editingProfileId;
  ProfileState? _profileState;

  Map<String, String> _configValues = {};
  bool _configLoading = false;
  String? _configPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _profileState = context.read<ProfileState>();
      _profileState!.addListener(_onProfileStateChanged);
      _loadCurrentProfile();
    });
  }

  void _onProfileStateChanged() {
    if (!mounted) return;
    _loadCurrentProfile();
  }

  void _loadCurrentProfile() {
    final profileState = context.read<ProfileState>();
    final profile = profileState.currentProfile;

    if (profile != null && _editingProfileId != profile.id) {
      setState(() {
        _nameController.text = profile.name;
        _uuidController.text = profile.uuid;
        _secretController.text = profile.secret;
        _serverUrlController.text = profile.serverUrl;
        _editingProfileId = profile.id;
        _isEditing = true;
        _testResult = null;
      });
      _loadConfig(profile);
    } else if (profile == null && _isEditing) {
      _clearForm();
    }
  }

  void _clearForm() {
    setState(() {
      _nameController.clear();
      _uuidController.clear();
      _secretController.clear();
      _serverUrlController.clear();
      _editingProfileId = null;
      _isEditing = false;
      _testResult = null;
      _configValues = {};
      _configPath = null;
      _configLoading = false;
    });
  }

  Future<void> _saveProfile() async {
    if (_formKey.currentState?.validate() != true) return;

    setState(() => _isLoading = true);

    final profileState = context.read<ProfileState>();
    final nameError = _validateProfileName(profileState);
    if (nameError != null) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(nameError)));
      return;
    }
    final existingProfile = profileState.currentProfile;
    final profile = Profile(
      id: _editingProfileId ?? const Uuid().v4(),
      name: _nameController.text.trim(),
      uuid: _uuidController.text.trim(),
      secret: _secretController.text,
      serverUrl: _serverUrlController.text.trim(),
      calendarSync: existingProfile?.calendarSync ?? false,
      recurrenceLimit: existingProfile?.recurrenceLimit ?? 1,
    );

    if (_isEditing) {
      final ok = await profileState.updateProfile(profile);
      if (!ok) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile name conflicts with an existing folder'),
          ),
        );
        return;
      }
    } else {
      await profileState.addProfile(profile);
      await profileState.setCurrentProfile(profile.id);
    }

    if (!mounted) return;
    setState(() => _isLoading = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isEditing ? 'Profile updated' : 'Profile created'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String? _validateProfileName(ProfileState profileState) {
    final trimmed = _nameController.text.trim();
    if (trimmed.isEmpty) return null;

    final sanitized = sanitizeProfileName(trimmed);
    for (final profile in profileState.profiles) {
      if (_isEditing && profile.id == _editingProfileId) continue;
      if (sanitizeProfileName(profile.name) == sanitized) {
        return 'Profile name conflicts with an existing folder name';
      }
    }
    return null;
  }

  Future<void> _testServer() async {
    final serverUrl = _serverUrlController.text.trim();
    if (serverUrl.isEmpty) {
      setState(() => _testResult = 'Please enter a server URL first');
      return;
    }

    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    try {
      final uri = Uri.parse(serverUrl);
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200 &&
          response.body.contains('TaskChampion sync server')) {
        setState(() => _testResult = 'Success: TaskChampion server verified');
      } else {
        setState(
          () => _testResult =
              'Error: Not a valid sync server (HTTP ${response.statusCode})',
        );
      }
    } catch (e) {
      setState(() => _testResult = 'Error: Connection failed');
    } finally {
      setState(() => _isTesting = false);
    }
  }

  Future<void> _loadConfig(Profile profile) async {
    setState(() => _configLoading = true);
    try {
      final taskState = context.read<TaskState>();
      if (taskState.currentProfileId != profile.id) {
        await taskState.loadProfile(profile, forceReload: true);
      }
      if (!mounted) return;
      final tm = taskState.taskManager;
      if (tm != null) {
        final service = TaskrcConfigService(tm);
        final values = await service.getAllConfig();
        final path = await TaskrcConfigService.resolveTaskrcPath(profile);
        if (!mounted) return;
        setState(() {
          _configValues = values;
          _configPath = path;
        });
      } else if (mounted) {
        setState(() {
          _configValues = {};
          _configPath = null;
        });
      }
    } catch (e) {
      debugPrint('Failed to load config: $e');
    } finally {
      if (mounted) setState(() => _configLoading = false);
    }
  }

  Future<void> _deleteCurrentProfile() async {
    if (_editingProfileId == null) return;

    final profileState = context.read<ProfileState>();
    final theme = Theme.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Profile?'),
        content: const Text(
          'This will permanently delete the profile and its task data from the current storage location.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.errorContainer,
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await profileState.deleteProfile(_editingProfileId!);
      if (mounted) _clearForm();
    }
  }

  @override
  void dispose() {
    _profileState?.removeListener(_onProfileStateChanged);
    _nameController.dispose();
    _uuidController.dispose();
    _secretController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Profiles & Sync',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_isEditing)
            IconButton(
              icon: Icon(Icons.delete_outline, color: colorScheme.error),
              onPressed: _deleteCurrentProfile,
              tooltip: 'Delete Profile',
            ),
          const SizedBox(width: 8),
        ],
      ),
      drawer: const AppDrawer(currentRoute: '/credentials'),
      body: Consumer<ProfileState>(
        builder: (context, profileState, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader(context, 'Active Profile'),
                  _buildGroupContainer(
                    context,
                    padding: const EdgeInsets.all(16),
                    child: DropdownButtonFormField<String>(
                      initialValue: profileState.currentProfileId,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.person_pin_outlined),
                        hintText: 'Create New Profile',
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('Add New Profile...'),
                        ),
                        ...profileState.profiles.map(
                          (p) => DropdownMenuItem(
                            value: p.id,
                            child: Text(p.name),
                          ),
                        ),
                      ],
                      onChanged: (id) async {
                        if (id == null) {
                          _clearForm();
                        } else {
                          final profile = profileState.profiles.firstWhere(
                            (p) => p.id == id,
                          );
                          await context.read<TaskState>().loadProfile(
                            profile,
                            forceReload: true,
                          );
                          if (!context.mounted) return;
                          await profileState.setCurrentProfile(id);
                        }
                      },
                    ),
                  ),

                  const SizedBox(height: 24),

                  _buildSectionHeader(context, 'Profile Configuration'),
                  _buildGroupContainer(
                    context,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        TextFormField(
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: 'Profile Name',
                            prefixIcon: Icon(Icons.badge_outlined),
                            hintText: 'e.g., Work, Personal',
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return 'Required';
                            }
                            final conflict = _validateProfileName(
                              context.read<ProfileState>(),
                            );
                            return conflict;
                          },
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _uuidController,
                          decoration: const InputDecoration(
                            labelText: 'Client UUID (Optional)',
                            prefixIcon: Icon(Icons.fingerprint),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _secretController,
                          decoration: const InputDecoration(
                            labelText: 'Encryption Secret (Optional)',
                            prefixIcon: Icon(Icons.key_outlined),
                          ),
                          obscureText: true,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _serverUrlController,
                          decoration: const InputDecoration(
                            labelText: 'Server URL (Optional)',
                            prefixIcon: Icon(Icons.dns_outlined),
                            hintText: 'https://sync.example.com',
                          ),
                          keyboardType: TextInputType.url,
                        ),

                        if (_testResult != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: _testResult!.contains('Success')
                                  ? Colors.green.withValues(alpha: 0.1)
                                  : colorScheme.errorContainer.withValues(
                                      alpha: 0.3,
                                    ),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _testResult!.contains('Success')
                                    ? Colors.green
                                    : colorScheme.error,
                                width: 0.5,
                              ),
                            ),
                            child: Text(
                              _testResult!,
                              style: TextStyle(
                                fontSize: 13,
                                color: _testResult!.contains('Success')
                                    ? Colors.green.shade800
                                    : colorScheme.error,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],

                        const SizedBox(height: 24),

                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _isTesting ? null : _testServer,
                                icon: _isTesting
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.network_check, size: 18),
                                label: const Text('Test Server'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _isLoading ? null : _saveProfile,
                                icon: _isLoading
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.save_outlined, size: 18),
                                label: Text(_isEditing ? 'Update' : 'Save'),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  _buildSectionHeader(context, 'Taskwarrior Config'),
                  _buildConfigSection(context, profileState),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildConfigSection(BuildContext context, ProfileState profileState) {
    final colorScheme = Theme.of(context).colorScheme;
    final profile = profileState.currentProfile;

    if (profile == null || !_isEditing || _editingProfileId != profile.id) {
      return _buildGroupContainer(
        context,
        padding: const EdgeInsets.all(20),
        child: Text(
          'Select a profile to view config',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    final taskState = context.read<TaskState>();
    final canAccessConfig = taskState.taskManager != null;
    final hasConfig = _configValues.isNotEmpty;
    final isLoaded = !_configLoading;

    return _buildGroupContainer(
      context,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // display file path
          Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 18,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _configPath ?? 'taskrc',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Taskwarrior-compatible config file in your profile data directory',
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          if (!isLoaded)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (!canAccessConfig)
            Text(
              'Load a profile to access config',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            )
          else if (!hasConfig)
            Text(
              'No config loaded',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            )
          else
            _buildConfigEntries(context, colorScheme),

          const SizedBox(height: 16),

          // action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: canAccessConfig && hasConfig
                      ? () => _showConfigEditor(context)
                      : null,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit Config'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showRawConfigEditor(context, profile),
                  icon: const Icon(Icons.code, size: 16),
                  label: const Text('View Raw'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConfigEntries(BuildContext context, ColorScheme colorScheme) {
    final priorityKeys = [
      'urgency.due.coefficient',
      'urgency.active.coefficient',
      'urgency.blocking.coefficient',
      'urgency.scheduled.coefficient',
      'urgency.age.coefficient',
      'urgency.uda.priority.H.coefficient',
      'urgency.uda.priority.M.coefficient',
      'urgency.uda.priority.L.coefficient',
    ];

    final entries = <Widget>[];
    for (final key in priorityKeys) {
      final value = _configValues[key];
      if (value != null) {
        entries.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    key,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => _editConfigValue(context, key, value),
                  child: Icon(
                    Icons.edit_square,
                    size: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: entries,
    );
  }

  Future<void> _editConfigValue(
    BuildContext context,
    String key,
    String currentValue,
  ) async {
    final newValue = await showDialog<String>(
      context: context,
      builder: (_) =>
          _ConfigValueDialog(configKey: key, currentValue: currentValue),
    );

    if (newValue != null && newValue != currentValue) {
      if (!context.mounted) return;
      try {
        final taskState = context.read<TaskState>();
        if (taskState.taskManager == null) return;
        final service = TaskrcConfigService(taskState.taskManager!);
        await service.setConfigValue(key, newValue);
        if (!context.mounted) return;
        setState(() => _configValues[key] = newValue);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Updated $key'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showConfigEditor(BuildContext context) async {
    final configList = _configValues.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final selected = await showModalBottomSheet<MapEntry<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.4,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scrollController) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Config Values',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Tap a value to edit',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.separated(
                          controller: scrollController,
                          itemCount: configList.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final entry = configList[index];
                            return ListTile(
                              dense: true,
                              title: Text(
                                entry.key,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              subtitle: Text(
                                entry.value,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              trailing: const Icon(
                                Icons.edit_outlined,
                                size: 16,
                              ),
                              onTap: () => Navigator.pop(
                                ctx,
                                MapEntry(entry.key, entry.value),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );

    if (selected == null || !context.mounted) return;
    _editConfigValue(context, selected.key, selected.value);
  }

  Future<void> _showRawConfigEditor(
    BuildContext context,
    Profile profile,
  ) async {
    final rawContent = await TaskrcConfigService.readRawContent(profile);
    if (!context.mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _RawConfigEditorDialog(initialContent: rawContent ?? ''),
    );

    if (result != null && result != (rawContent ?? '')) {
      if (!context.mounted) return;
      final taskState = context.read<TaskState>();
      final tm = taskState.taskManager;
      final issues = tm == null
          ? <ConfigIssue>[]
          : await TaskrcConfigService(tm).validateTaskrc(result);
      if (!context.mounted) return;
      if (issues.isNotEmpty) {
        final proceed = await _showValidationWarning(context, issues);
        if (!proceed || !context.mounted) return;
      }

      final ok = await TaskrcConfigService.writeRawContent(profile, result);
      if (!context.mounted) return;
      if (ok) {
        try {
          final taskState = context.read<TaskState>();
          await taskState.loadProfile(profile, forceReload: true);
          await _loadConfig(profile);
        } catch (_) {}
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Config saved.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to write config')));
      }
    }
  }

  Future<bool> _showValidationWarning(
    BuildContext context,
    List<ConfigIssue> issues,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange.shade700,
              size: 22,
            ),
            const SizedBox(width: 8),
            const Text('Config Issues', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${issues.length} issue${issues.length == 1 ? '' : 's'} found:',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                for (final issue in issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'L${issue.line}:',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            issue.message,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'These lines will be ignored. Save anyway?',
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save Anyway'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildGroupContainer(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry? padding,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
        ),
      ),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    );
  }
}

class _ConfigValueDialog extends StatefulWidget {
  const _ConfigValueDialog({
    required this.configKey,
    required this.currentValue,
  });

  final String configKey;
  final String currentValue;

  @override
  State<_ConfigValueDialog> createState() => _ConfigValueDialogState();
}

class _ConfigValueDialogState extends State<_ConfigValueDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.configKey,
        style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
      ),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          labelText: 'Value',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _RawConfigEditorDialog extends StatefulWidget {
  const _RawConfigEditorDialog({required this.initialContent});

  final String initialContent;

  @override
  State<_RawConfigEditorDialog> createState() => _RawConfigEditorDialogState();
}

class _RawConfigEditorDialogState extends State<_RawConfigEditorDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.code, size: 20),
          const SizedBox(width: 8),
          const Expanded(child: Text('taskrc', style: TextStyle(fontSize: 16))),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _controller.text));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.5,
        child: TextField(
          controller: _controller,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.all(12),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
