import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/profile_state.dart';
import 'package:taskdroid/version.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, required this.currentRoute});

  final String currentRoute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Drawer(
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, colorScheme, theme),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  _NavButton(
                    icon: Icons.home_outlined,
                    activeIcon: Icons.home,
                    label: 'Home',
                    isSelected: currentRoute == '/',
                    onTap: () => _navigate(context, '/'),
                  ),
                  _NavButton(
                    icon: Icons.badge_outlined,
                    activeIcon: Icons.badge,
                    label: 'Profiles & Sync',
                    isSelected: currentRoute == '/credentials',
                    onTap: () => _navigate(context, '/credentials'),
                  ),
                  _NavButton(
                    icon: Icons.swap_vert_circle_outlined,
                    activeIcon: Icons.swap_vert_circle,
                    label: 'Data Management',
                    isSelected: currentRoute == '/data',
                    onTap: () => _navigate(context, '/data'),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: 8.0,
                      horizontal: 16,
                    ),
                    child: Divider(),
                  ),
                  _NavButton(
                    icon: Icons.settings_outlined,
                    activeIcon: Icons.settings,
                    label: 'Settings',
                    isSelected: currentRoute == '/settings',
                    onTap: () => _navigate(context, '/settings'),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              'Taskdroid ${_getVersion()}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getVersion() {
    final base = AppVersion.version.split('+').first;
    return kDebugMode ? '$base (debug)' : base;
  }

  Widget _buildHeader(
    BuildContext context,
    ColorScheme colorScheme,
    ThemeData theme,
  ) {
    return Consumer<ProfileState>(
      builder: (context, profileState, _) {
        final currentProfile = profileState.currentProfile;
        final initials = (currentProfile?.name.isNotEmpty ?? false)
            ? currentProfile!.name[0].toUpperCase()
            : 'T';

        // Get safe area padding for status bar
        final topPadding = MediaQuery.of(context).padding.top;

        return Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(20, topPadding + 20, 20, 20),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: const BorderRadius.only(
              bottomRight: Radius.circular(28),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
                child: Text(
                  initials,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Welcome back,',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              // Profile Switcher "Pill" with fixed width handling
              InkWell(
                onTap: () => _showProfileSelector(context, profileState),
                borderRadius: BorderRadius.circular(12),
                splashColor: colorScheme.primary.withValues(alpha: 0.2),
                highlightColor: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 120),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: colorScheme.primary.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          currentProfile?.name ?? 'Select Profile',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onPrimaryContainer,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.unfold_more_rounded,
                        size: 18,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _navigate(BuildContext context, String route) {
    Navigator.pop(context);

    if (currentRoute == route) return;

    if (route == '/') {
      Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
    } else {
      Navigator.pushNamed(context, route);
    }
  }

  Future<void> _showProfileSelector(
    BuildContext context,
    ProfileState state,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final profiles = state.profiles;

    if (profiles.isEmpty) {
      // no profiles to show
      Navigator.pop(context); // close modal
      Navigator.pop(context); // close drawer
      Navigator.pushNamed(context, '/credentials');
      return;
    }

    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Switch Profile',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...profiles.map((profile) {
              final isCurrent = profile.id == state.currentProfileId;
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: CircleAvatar(
                  backgroundColor: isCurrent
                      ? colorScheme.primary
                      : colorScheme.surfaceContainerHighest,
                  foregroundColor: isCurrent
                      ? colorScheme.onPrimary
                      : colorScheme.onSurfaceVariant,
                  child: Text(profile.name[0].toUpperCase()),
                ),
                title: Text(
                  profile.name,
                  style: TextStyle(
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                trailing: isCurrent
                    ? Icon(Icons.check_circle, color: colorScheme.primary)
                    : null,
                onTap: () async {
                  // show loading while switching
                  Navigator.pop(context); // close modal

                  try {
                    await state.setCurrentProfile(profile.id);
                    HapticFeedback.selectionClick();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to switch profile: $e'),
                          backgroundColor: colorScheme.error,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  }
                },
              );
            }),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavButton({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        selected: isSelected,
        iconColor: colorScheme.onSurfaceVariant,
        textColor: colorScheme.onSurfaceVariant,
        selectedColor: colorScheme.onSecondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        tileColor: Colors.transparent,
        selectedTileColor: colorScheme.secondaryContainer,
        leading: Icon(isSelected ? activeIcon : icon),
        title: Text(
          label,
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}
