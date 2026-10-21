import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/models/profile.dart';
import 'package:taskdroid/providers/app_state.dart';
import 'package:taskdroid/providers/profile_state.dart';
import 'package:taskdroid/services/calendar_service.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:uuid/uuid.dart';

class OnboardingPage extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingPage({super.key, required this.onComplete});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pageController = PageController();
  final _syncFormKey = GlobalKey<FormState>();
  int _currentStep = 0;
  static const _totalSteps = 5;

  // 1 - name
  final _nameController = TextEditingController();
  final _nameFormKey = GlobalKey<FormState>();

  // 2 - welcome

  // 3 - theme
  bool _darkTheme = false;

  // 4 - calendar
  bool _calendarSync = false;
  bool _requestingCalendar = false;

  // 5 - sync
  final _serverUrlController = TextEditingController();
  final _uuidController = TextEditingController();
  final _secretController = TextEditingController();
  bool _testingServer = false;
  bool _serverTestSuccess = false;
  String? _serverTestResult;

  @override
  void initState() {
    super.initState();
    _darkTheme =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _serverUrlController.dispose();
    _uuidController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentStep == 0) {
      if (_nameFormKey.currentState?.validate() != true) return;
    }
    if (_currentStep < _totalSteps - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.fastOutSlowIn,
      );
    }
  }

  void _prevPage() {
    if (_currentStep > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.fastOutSlowIn,
      );
    }
  }

  bool _isCreating = false;

  Future<void> _createProfile({required bool skipSync}) async {
    if (_isCreating) return;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _pageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.fastOutSlowIn,
      );
      return;
    }

    if (!skipSync && _syncFormKey.currentState != null) {
      if (!_syncFormKey.currentState!.validate()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please fix the validation errors above'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    setState(() => _isCreating = true);

    final profile = Profile(
      id: const Uuid().v4(),
      name: name,
      uuid: skipSync ? '' : _uuidController.text.trim(),
      secret: skipSync ? '' : _secretController.text,
      serverUrl: skipSync ? '' : _serverUrlController.text.trim(),
      calendarSync: _calendarSync,
    );

    final profileState = context.read<ProfileState>();
    await profileState.addProfile(profile);
    await profileState.setCurrentProfile(profile.id);

    if (mounted) {
      widget.onComplete();
    }
  }

  Future<void> _finish() async => _createProfile(skipSync: false);
  Future<void> _skipAndFinish() async => _createProfile(skipSync: true);

  Future<void> _testServer() async {
    final url = _serverUrlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _serverTestSuccess = false;
        _serverTestResult = 'Please enter a server URL';
      });
      return;
    }

    setState(() {
      _testingServer = true;
      _serverTestSuccess = false;
      _serverTestResult = null;
    });

    try {
      final result = await testServer(url: url);
      if (!mounted) return;
      setState(() {
        _serverTestSuccess = result.success;
        _serverTestResult = result.message;
        _testingServer = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverTestSuccess = false;
        _serverTestResult = 'Error: Connection failed: $e';
        _testingServer = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        const SizedBox(height: 24),
        Expanded(
          child: PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (index) => setState(() => _currentStep = index),
            children: [
              _buildNameStep(theme),
              _buildWelcomeStep(theme),
              _buildThemeStep(theme),
              _buildCalendarStep(theme),
              _buildSyncStep(theme),
            ],
          ),
        ),
        _buildBottomBar(theme),
      ],
    );
  }

  Widget _buildNameStep(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Form(
          key: _nameFormKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.5,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.person_outline,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                "What should we call you?",
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                "This will be the name for your local profile. You can add more profiles later.",
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              TextFormField(
                controller: _nameController,
                autofocus: true,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => _nextPage(),
                decoration: const InputDecoration(
                  labelText: 'Profile Name',
                  hintText: 'e.g., Work, Personal',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a profile name';
                  }
                  final trimmed = value.trim();
                  final profileState = context.read<ProfileState>();
                  final hasDuplicate = profileState.profiles.any(
                    (p) => p.name.toLowerCase() == trimmed.toLowerCase(),
                  );
                  if (hasDuplicate) {
                    return 'A profile with this name already exists';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWelcomeStep(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.task_alt, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 24),
            Text(
              'Welcome to Taskdroid',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'A powerful, offline-first task manager powered by TaskChampion.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            _buildFeatureItem(
              theme,
              Icons.format_list_bulleted,
              'Task Management',
              'Organize tasks with projects, tags, priorities, and due dates.',
            ),
            _buildFeatureItem(
              theme,
              Icons.sync,
              'Sync Across Devices',
              'Connect to a TaskChampion sync server to keep tasks in sync.',
            ),
            _buildFeatureItem(
              theme,
              Icons.calendar_today,
              'Calendar Integration',
              'Mirror tasks with due dates to your system calendar automatically.',
            ),
            _buildFeatureItem(
              theme,
              Icons.speed,
              'Smart Priorities',
              'Automatic urgency scoring helps you focus on what matters most.',
            ),
            _buildFeatureItem(
              theme,
              Icons.filter_alt,
              'Filter Presets',
              'Save and quickly switch between custom task filters.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureItem(
    ThemeData theme,
    IconData icon,
    String title,
    String description,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              color: theme.colorScheme.onPrimaryContainer,
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeStep(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.5,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.palette_outlined,
                size: 64,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Choose your theme',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Select your preferred appearance. You can always change this later in Settings.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 48),
            Row(
              children: [
                Expanded(
                  child: _buildThemeCard(
                    theme,
                    'Light',
                    Icons.light_mode,
                    !_darkTheme,
                    () {
                      setState(() => _darkTheme = false);
                      context.read<AppState>().setDarkTheme(false);
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildThemeCard(
                    theme,
                    'Dark',
                    Icons.dark_mode,
                    _darkTheme,
                    () {
                      setState(() => _darkTheme = true);
                      context.read<AppState>().setDarkTheme(true);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeCard(
    ThemeData theme,
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 32),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline.withValues(alpha: 0.2),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 48,
              color: selected
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              label,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendarStep(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.5,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.calendar_month,
                size: 64,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Calendar Sync',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Allow Taskdroid to automatically mirror tasks with due dates directly to your device calendar.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 48),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.1),
                ),
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Enable Calendar Sync',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: _requestingCalendar
                    ? const Text('Requesting permission...')
                    : Text(
                        _calendarSync
                            ? 'Calendar sync is active'
                            : 'Tap to grant permissions',
                      ),
                value: _calendarSync,
                activeThumbColor: theme.colorScheme.primary,
                onChanged: _requestingCalendar
                    ? null
                    : (value) async {
                        if (value) {
                          setState(() => _requestingCalendar = true);
                          final service = CalendarService();
                          final hasPermission = await service
                              .requestPermissions();
                          if (!mounted) return;
                          setState(() {
                            _requestingCalendar = false;
                            _calendarSync = hasPermission;
                          });
                          if (!hasPermission) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Calendar permission denied. You can enable it later.',
                                ),
                              ),
                            );
                          }
                        } else {
                          setState(() => _calendarSync = false);
                        }
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncStep(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Form(
          key: _syncFormKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.5,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.cloud_sync_outlined,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Sync Server',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Connect to a TaskChampion sync server to backup and share tasks. You can skip this and set it up later.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              TextFormField(
                controller: _serverUrlController,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://sync.example.com',
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _uuidController,
                decoration: const InputDecoration(
                  labelText: 'Client UUID',
                  prefixIcon: Icon(Icons.fingerprint),
                  hintText: '123e4567-e89b-12d3-a456-426614174000',
                ),
                validator: (value) {
                  if (value != null && value.isNotEmpty) {
                    final uuidRegex = RegExp(
                      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
                      caseSensitive: false,
                    );
                    if (!uuidRegex.hasMatch(value)) {
                      return 'Enter a valid UUID';
                    }
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _secretController,
                decoration: const InputDecoration(
                  labelText: 'Encryption Secret',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: OutlinedButton.icon(
                  onPressed: _testingServer ? null : _testServer,
                  icon: _testingServer
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check),
                  label: Text(
                    _testingServer
                        ? 'Testing Connection...'
                        : 'Test Server Connection',
                  ),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              if (_serverTestResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _serverTestResult!,
                        style: TextStyle(
                          color: _serverTestSuccess
                              ? Colors.green
                              : theme.colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (!_serverTestSuccess &&
                          (_serverTestResult!.toLowerCase().contains(
                                'certificate',
                              ) ||
                              _serverTestResult!.toLowerCase().contains(
                                'unknownissuer',
                              )))
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Using a private CA? Install it in Android Settings, '
                            'then enable "Trust user CA certificates" in '
                            'Taskdroid Settings and restart.',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme) {
    final isLastStep = _currentStep == _totalSteps - 1;

    return Container(
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
        children: [
          // back btn
          if (_currentStep > 0)
            TextButton(
              onPressed: _isCreating ? null : _prevPage,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Back',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            )
          else
            const SizedBox(width: 70),

          const Spacer(),

          // dots progress
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(_totalSteps, (index) {
              final isActive = index == _currentStep;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.fastOutSlowIn,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: isActive ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),

          const Spacer(),

          if (isLastStep) ...[
            TextButton(
              onPressed: _isCreating ? null : _skipAndFinish,
              child: Text(
                'Skip',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _isCreating ? null : _finish,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _isCreating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      'Finish',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
            ),
          ] else ...[
            FilledButton(
              onPressed: _isCreating ? null : _nextPage,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text(
                'Next',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
