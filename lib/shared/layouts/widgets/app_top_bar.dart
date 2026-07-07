import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/app_update/logic/app_updater_service.dart';
import '../../../features/auth/logic/auth_controller.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../features/provider_node/logic/provider_run_controller.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../app_info.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/status_dot.dart';

/// The Tailscale-style title bar: the active grid + account avatar sit on the
/// right, with the left kept clear past the macOS window controls. Doubles as
/// the window drag handle.
class AppTopBar extends ConsumerWidget {
  const AppTopBar({super.key});

  static const double height = 52;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final email = session.userEmail ?? '—';
    // Leave room for the macOS traffic-light buttons under the hidden title bar.
    final leftInset = Platform.isMacOS ? 78.0 : 16.0;

    return DragToMoveArea(
      child: GlassSurface(
        borderRadius: BorderRadius.zero,
        border: const Border(bottom: BorderSide(color: AppGlass.border)),
        padding: EdgeInsets.only(left: leftInset, right: 12),
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              // Account avatar + active grid group on the right; the left stays
              // clear of the macOS traffic-light buttons.
              const Spacer(),
              const _Account(),
              const SizedBox(width: 12),
              _AccountMenu(
                  name: session.user['name'] as String? ?? email, email: email),
            ],
          ),
        ),
      ),
    );
  }
}

/// The active grid shown at the right of the title bar — name + live
/// Running / Stopped dot. The account email lives in the avatar menu now, so the
/// bar stays uncluttered while still saying which grid you're working in.
class _Account extends ConsumerWidget {
  const _Account();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(selectedNetworkProvider);
    if (grid == null) return const SizedBox.shrink();
    return _CurrentGridLabel(grid: grid);
  }
}

/// The active grid at the right of the title bar — a live Running / Stopped dot,
/// a faint "Grid ·" caption, then the grid name (shared cache with the list +
/// detail). No box: it reads as a label, so you always know which grid you're
/// working in without it competing with the window chrome.
class _CurrentGridLabel extends ConsumerWidget {
  const _CurrentGridLabel({required this.grid});
  final NetworkCredential grid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state =
        ref.watch(gridOverviewForProvider(grid.networkId)).asData?.value.state;
    final running = state?.toLowerCase() == 'running';
    return ConstrainedBox(
      // Cap the width and ellipsize so a long grid name can't overflow into the
      // avatar or off the bar on a narrow window.
      constraints: const BoxConstraints(maxWidth: 280),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(
              color: running ? AppPalette.online : AppPalette.offline, size: 8),
          const SizedBox(width: 8),
          Flexible(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: 'Grid · ',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppPalette.textSecondary),
                ),
                TextSpan(
                  text: grid.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w600),
                ),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Avatar that opens an account menu: email, "Check for updates", the app
/// version, and Sign out. Opening the menu also kicks off a silent update check,
/// so a newer build surfaces just from viewing the version — no separate tap.
class _AccountMenu extends ConsumerWidget {
  const _AccountMenu({required this.name, required this.email});
  final String name;
  final String email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final updater = ref.read(appUpdaterServiceProvider);
    final version = ref.watch(appVersionProvider).asData?.value;
    // Surface every check outcome as a toast so an explicit "Check for updates"
    // never silently does nothing — Sparkle only shows its own UI on success.
    ref.listen(appUpdateStatusProvider, (_, next) {
      final status = next.asData?.value;
      if (status != null) _showUpdateToast(context, status);
    });
    return PopupMenuButton<String>(
      tooltip: name,
      offset: const Offset(0, 42),
      onSelected: (value) async {
        if (value == 'check_updates') {
          await updater.checkForUpdates();
          return;
        }
        if (value != 'logout') return;
        final engineRunning =
            ref.read(providerRunControllerProvider) is ProviderRunActive;
        if (await _confirmSignOut(context, engineRunning: engineRunning)) {
          await ref.read(authControllerProvider.notifier).logout();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Text(email, style: const TextStyle(fontSize: 12.5)),
        ),
        const PopupMenuDivider(),
        if (updater.isEnabled)
          const PopupMenuItem(
            value: 'check_updates',
            child: Row(
              children: [
                Icon(Icons.system_update_alt, size: 18),
                SizedBox(width: 10),
                Text('Check for updates'),
              ],
            ),
          ),
        if (version != null)
          PopupMenuItem(
            enabled: false,
            height: 32,
            child: Text('Version $version',
                style: const TextStyle(
                    fontSize: 11.5, color: AppPalette.textFaint)),
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
      child: CircleAvatar(
        radius: 14,
        backgroundColor: AppPalette.accentMuted,
        child: Text(initial,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  Future<bool> _confirmSignOut(BuildContext context,
      {required bool engineRunning}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(engineRunning
            ? "You'll be signed out and need to sign in again. Your running "
                'engine will be stopped.'
            : "You'll be signed out and need to sign in again."),
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

/// Toasts a "Check for updates" outcome so the tap always resolves to feedback —
/// Sparkle shows its own dialog only when it succeeds, so this covers the
/// checking / up-to-date / failed states it stays silent on.
void _showUpdateToast(BuildContext context, UpdateStatus status) {
  final message = switch (status) {
    UpdateChecking() => 'Checking for updates…',
    UpdateUpToDate() => "You're on the latest version.",
    UpdateAvailable(:final version) => version == null
        ? 'An update is available — follow the prompt to install.'
        : 'Update available: $version — follow the prompt to install.',
    UpdateFailed(:final message) => "Couldn't check for updates: $message",
  };
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}
