import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell_state.dart';
import 'settings_shell.dart';

/// Opens the settings area — grids, engines, the guide — as a modal dialog on
/// [tab]. The app itself is just chat now; this is where the plumbing lives, one
/// click away in the account menu instead of taking up a sidebar.
///
/// Returns the dialog's future so callers can await it if they need to.
Future<void> showSettingsDialog(WidgetRef ref, SettingsTab tab) {
  ref.read(settingsTabProvider.notifier).select(tab);
  return showDialog<void>(
    context: ref.context,
    builder: (_) => const _SettingsDialog(),
  );
}

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Take nearly the whole window (a rail + grid list + detail need the room),
    // leaving a margin, and cap it so it doesn't sprawl on a huge display. Never
    // wider than the window, so it fits even when resized small.
    final width = (size.width - 48).clamp(360.0, 1080.0);
    final height = (size.height - 48).clamp(360.0, 780.0);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            const _DialogHeader(),
            const Divider(height: 1),
            const Expanded(child: SettingsShell()),
          ],
        ),
      ),
    );
  }
}

/// A thin title bar with a close button, so the dialog reads as a window the
/// user can dismiss without hunting for the backdrop.
class _DialogHeader extends StatelessWidget {
  const _DialogHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 10, 10),
      child: Row(
        children: [
          Text('Settings', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}
