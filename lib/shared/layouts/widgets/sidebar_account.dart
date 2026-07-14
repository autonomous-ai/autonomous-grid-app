import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/app_update/logic/app_updater_service.dart';
import '../../../features/auth/logic/auth_controller.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../../features/provider_node/logic/provider_run_controller.dart';
import '../../app_info.dart';
import '../../theme/app_theme.dart';
import '../../widgets/anchored_menu_position.dart';
import '../shell_state.dart';

const _accountMenuWidth = 232.0;
const _accountMenuSize = Size(_accountMenuWidth, 200);

/// The menu entries that aren't a section — kept apart from `ShellSection.name`
/// so a section can never collide with one.
const _settingsValue = 'settings';
const _updatesValue = 'check_updates';
const _logoutValue = 'logout';

/// The sidebar's foot: who's signed in, and the menu that hangs off it — check
/// for updates, the app version, sign out.
///
/// Wears a dot while a newer build is waiting, so an update is noticed instead of
/// having to be hunted for. Check outcomes are toasted app-wide by
/// `UpdateToastScope`.
class SidebarAccount extends ConsumerStatefulWidget {
  const SidebarAccount({super.key});

  @override
  ConsumerState<SidebarAccount> createState() => _SidebarAccountState();
}

class _SidebarAccountState extends ConsumerState<SidebarAccount> {
  final _menu = MenuController();

  void _toggleMenu(BuildContext context, MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: _accountMenuSize,
        margin: 8,
        gap: 8,
        preferAbove: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final email = session.userEmail ?? '—';
    final name = session.user['name'] as String? ?? email;
    final updater = ref.read(appUpdaterServiceProvider);
    final version = ref.watch(appVersionProvider).asData?.value;
    final status = ref.watch(appUpdateStatusProvider).asData?.value;
    final available = status is UpdateAvailable ? status : null;

    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        minimumSize: const WidgetStatePropertyAll(Size(_accountMenuWidth, 0)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      menuChildren: [
        _AccountMenuContent(
          version: version,
          updateAvailable: available,
          updaterSupported: updater.isSupported,
          onSelected: (value) => _onSelected(context, ref, updater, value),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Account',
        child: Semantics(
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleMenu(context, controller),
            child: _AccountRow(
              name: name,
              email: email,
              updateAvailable: available != null,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onSelected(
    BuildContext context,
    WidgetRef ref,
    AppUpdaterService updater,
    String value,
  ) async {
    _menu.close();
    if (value == _updatesValue) {
      await updater.checkForUpdates();
      return;
    }
    if (value == _settingsValue) {
      ref.read(shellSectionProvider.notifier).select(kDefaultSettingsSection);
      return;
    }
    if (value != _logoutValue) return;
    final engineRunning =
        ref.read(providerRunControllerProvider) is ProviderRunActive;
    if (!context.mounted) return;
    if (await _confirmSignOut(context, engineRunning: engineRunning)) {
      await ref.read(authControllerProvider.notifier).logout();
    }
  }

  Future<bool> _confirmSignOut(
    BuildContext context, {
    required bool engineRunning,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(
          engineRunning
              ? "You'll be signed out and need to sign in again. The model "
                    'running on this computer will be stopped.'
              : "You'll be signed out and need to sign in again.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

class _AccountMenuContent extends StatelessWidget {
  const _AccountMenuContent({
    required this.version,
    required this.updateAvailable,
    required this.updaterSupported,
    required this.onSelected,
  });

  final String? version;
  final UpdateAvailable? updateAvailable;
  final bool updaterSupported;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _accountMenuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // One door to the setup screens — grids, this computer, Telegram, the
          // guide. They were four loose menu entries; a menu is a bad place to
          // keep things you have to come back to.
          _AccountMenuItem(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onPressed: () => onSelected(_settingsValue),
          ),
          const _AccountMenuDivider(),
          if (updaterSupported)
            _AccountMenuItem(
              icon: Icons.system_update_alt,
              iconColor: updateAvailable == null
                  ? AppPalette.textSecondary
                  : AppPalette.brandBolt,
              label: updateAvailable == null
                  ? 'Check for updates'
                  : 'Update to ${updateAvailable?.version ?? 'the latest'}',
              onPressed: () => onSelected(_updatesValue),
            ),
          if (version != null) _AccountVersion(version: version!),
          const _AccountMenuDivider(),
          _AccountMenuItem(
            icon: Icons.logout,
            label: 'Sign out',
            onPressed: () => onSelected(_logoutValue),
          ),
        ],
      ),
    );
  }
}

class _AccountMenuItem extends StatelessWidget {
  const _AccountMenuItem({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconColor = AppPalette.textSecondary,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return MenuItemButton(
      onPressed: onPressed,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        overlayColor: WidgetStatePropertyAll(AppSurface.hoverFill),
        minimumSize: const WidgetStatePropertyAll(Size(_accountMenuWidth, 44)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountVersion extends StatelessWidget {
  const _AccountVersion({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
      child: Text(
        'Version $version',
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: AppPalette.textFaint,
        ),
      ),
    );
  }
}

class _AccountMenuDivider extends StatelessWidget {
  const _AccountMenuDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 5),
      child: Divider(height: 1),
    );
  }
}

/// The clickable face of the account menu: initial, name, email.
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.name,
    required this.email,
    required this.updateAvailable,
  });

  final String name;
  final String email;
  final bool updateAvailable;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 9),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: const Color(0x08000000),
          boxShadow: const [
            BoxShadow(
              color: Color(0x06000000),
              blurRadius: 10,
              offset: Offset(0, 2),
              spreadRadius: -7,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 7, 7),
          child: Row(
            children: [
              _Avatar(initial: initial, updateAvailable: updateAvailable),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
              const Icon(
                Icons.more_horiz,
                size: 18,
                color: AppPalette.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initial, required this.updateAvailable});

  final String initial;
  final bool updateAvailable;

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: 13,
      backgroundColor: AppPalette.accentMuted,
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (!updateAvailable) return avatar;
    return Badge(
      backgroundColor: AppPalette.brandBolt,
      smallSize: 8,
      child: avatar,
    );
  }
}
