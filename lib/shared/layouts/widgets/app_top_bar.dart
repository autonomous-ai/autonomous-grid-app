import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/auth/logic/auth_controller.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../features/provider_node/logic/provider_run_controller.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';

/// The Tailscale-style title bar: account on the left, quick actions + avatar
/// on the right. Doubles as the window drag handle.
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
      child: Container(
        height: height,
        color: AppPalette.panelBg,
        padding: EdgeInsets.only(left: leftInset, right: 12),
        child: Row(
          children: [
            _Account(email: email),
            const Spacer(),
            _AccountMenu(name: session.user['name'] as String? ?? email, email: email),
          ],
        ),
      ),
    );
  }
}

class _Account extends ConsumerWidget {
  const _Account({required this.email});
  final String email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final grid = ref.watch(selectedNetworkProvider);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(email,
            style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textPrimary, fontWeight: FontWeight.w500)),
        if (grid != null) _GridLine(grid: grid),
      ],
    );
  }
}

/// The selected grid shown under the account email — its name with a live
/// Running / Stopped dot (shared cache with the list + detail), so the line says
/// something true instead of a blanket "Connected".
class _GridLine extends ConsumerWidget {
  const _GridLine({required this.grid});
  final NetworkCredential grid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state =
        ref.watch(gridOverviewForProvider(grid.networkId)).asData?.value.state;
    final running = state?.toLowerCase() == 'running';
    return Row(
      children: [
        StatusDot(
            color: running ? AppPalette.online : AppPalette.offline, size: 7),
        const SizedBox(width: 6),
        Text(grid.name,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppPalette.textSecondary)),
      ],
    );
  }
}

/// Avatar that opens an account menu (email header + Sign out).
class _AccountMenu extends ConsumerWidget {
  const _AccountMenu({required this.name, required this.email});
  final String name;
  final String email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return PopupMenuButton<String>(
      tooltip: name,
      offset: const Offset(0, 42),
      onSelected: (value) async {
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
