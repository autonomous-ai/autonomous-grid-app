import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/app_update/logic/app_updater_service.dart';
import '../../../features/auth/logic/auth_controller.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../../features/provider_node/logic/provider_run_controller.dart';
import '../../app_info.dart';
import '../../theme/app_theme.dart';

/// The sidebar's foot: who's signed in, and the menu that hangs off it — check
/// for updates, the app version, sign out.
///
/// Wears a dot while a newer build is waiting, so an update is noticed instead of
/// having to be hunted for. Check outcomes are toasted app-wide by
/// `UpdateToastScope`.
class SidebarAccount extends ConsumerWidget {
  const SidebarAccount({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final email = session.userEmail ?? '—';
    final name = session.user['name'] as String? ?? email;
    final updater = ref.read(appUpdaterServiceProvider);
    final version = ref.watch(appVersionProvider).asData?.value;
    final status = ref.watch(appUpdateStatusProvider).asData?.value;
    final available = status is UpdateAvailable ? status : null;

    return PopupMenuButton<String>(
      tooltip: 'Account',
      offset: const Offset(0, -8),
      position: PopupMenuPosition.over,
      onSelected: (value) => _onSelected(context, ref, updater, value),
      itemBuilder: (context) => [
        if (updater.isSupported)
          PopupMenuItem(
            value: 'check_updates',
            child: Row(
              children: [
                Icon(
                  Icons.system_update_alt,
                  size: 18,
                  color: available == null ? null : AppPalette.brandBolt,
                ),
                const SizedBox(width: 10),
                Text(
                  available == null
                      ? 'Check for updates'
                      : 'Update to ${available.version ?? 'the latest version'}',
                ),
              ],
            ),
          ),
        if (version != null)
          PopupMenuItem(
            enabled: false,
            height: 32,
            child: Text(
              'Version $version',
              style: const TextStyle(
                fontSize: 11.5,
                color: AppPalette.textFaint,
              ),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'logout',
          child: Row(
            children: [
              Icon(Icons.logout, size: 18),
              SizedBox(width: 10),
              Text('Sign out'),
            ],
          ),
        ),
      ],
      child: _AccountRow(
        name: name,
        email: email,
        updateAvailable: available != null,
      ),
    );
  }

  Future<void> _onSelected(
    BuildContext context,
    WidgetRef ref,
    AppUpdaterService updater,
    String value,
  ) async {
    if (value == 'check_updates') {
      await updater.checkForUpdates();
      return;
    }
    if (value != 'logout') return;
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
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          _Avatar(initial: initial, updateAvailable: updateAvailable),
          const SizedBox(width: 10),
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
          const Icon(Icons.more_horiz, size: 18, color: AppPalette.textFaint),
        ],
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
