import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';
import '../shell_state.dart';

/// The Tailscale-style title bar: connection toggle + account on the left,
/// quick actions + avatar on the right. Doubles as the window drag handle.
class AppTopBar extends ConsumerWidget {
  const AppTopBar({super.key});

  static const double height = 52;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(connectedProvider);
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
            Switch(
              value: connected,
              onChanged: (_) => ref.read(connectedProvider.notifier).toggle(),
            ),
            const SizedBox(width: 12),
            _Account(email: email, connected: connected),
            const Spacer(),
            const _QuickActions(),
            const SizedBox(width: 8),
            _Avatar(name: session.user['name'] as String? ?? email),
          ],
        ),
      ),
    );
  }
}

class _Account extends StatelessWidget {
  const _Account({required this.email, required this.connected});
  final String email;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(email,
            style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textPrimary, fontWeight: FontWeight.w500)),
        Row(
          children: [
            StatusDot(
                color: connected ? AppPalette.online : AppPalette.offline,
                size: 7),
            const SizedBox(width: 6),
            Text(connected ? 'Connected' : 'Disconnected',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppPalette.textSecondary)),
          ],
        ),
      ],
    );
  }
}

class _QuickActions extends ConsumerWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isProvider = ref.watch(selectedNetworkProvider)?.isProvider ?? false;
    return Row(
      children: [
        // Provider/Models shortcuts only make sense on a provider network.
        if (isProvider) ...[
          _IconBtn(
            icon: Icons.devices_outlined,
            tooltip: 'Provider',
            onTap: () => ref
                .read(navSectionProvider.notifier)
                .select(NavSection.provider),
          ),
          _IconBtn(
            icon: Icons.memory_outlined,
            tooltip: 'Models',
            onTap: () =>
                ref.read(navSectionProvider.notifier).select(NavSection.models),
          ),
        ],
        _IconBtn(
          icon: Icons.refresh,
          tooltip: 'Refresh',
          onTap: () => ref.invalidate(sessionProvider),
        ),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn(
      {required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      color: AppPalette.textSecondary,
      onPressed: onTap,
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Tooltip(
      message: name,
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
}
