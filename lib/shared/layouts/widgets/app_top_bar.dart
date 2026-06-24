import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/auth/logic/auth_controller.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';
import '../shell_state.dart';

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
            const _QuickActions(),
            const SizedBox(width: 8),
            _AccountMenu(name: session.user['name'] as String? ?? email, email: email),
          ],
        ),
      ),
    );
  }
}

class _Account extends StatelessWidget {
  const _Account({required this.email});
  final String email;

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
            const StatusDot(color: AppPalette.online, size: 7),
            const SizedBox(width: 6),
            Text('Connected',
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
    final canManage =
        ref.watch(selectedNetworkProvider)?.canManageProvider ?? false;
    return Row(
      children: [
        // Provider/Models shortcuts only show where those tabs are available.
        if (canManage) ...[
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
        if (value == 'logout' && await _confirmSignOut(context)) {
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

  Future<bool> _confirmSignOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
            'Your local credentials will be cleared — you\'ll need to log in again.'),
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
