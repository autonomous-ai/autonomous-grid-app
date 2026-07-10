import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/codex_providers.dart';
import 'codex_setup_dialog.dart';

/// The Chat-tab toggle for experimental Agent mode. Selecting it turns the next
/// send into a codex agent run; if codex isn't installed yet, it opens the
/// one-time setup and only turns on once that succeeds.
///
/// Rendered as a button (not a chip) so it stands 40px tall like the Grid/Model
/// fields beside it, and so the on-state gets `onPrimary` (white) text and icon
/// on the blue fill for legible contrast.
class AgentModeToggle extends ConsumerWidget {
  const AgentModeToggle({super.key});

  static const _icon = Icon(Icons.smart_toy_outlined, size: 18);
  static const _label = Text('Agent');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(codexAgentEnabledProvider);
    return Tooltip(
      message:
          'Agent (experimental): an assistant that reads files and runs '
          "read-only tasks via Codex, using your grid's model.",
      child: on
          ? FilledButton.icon(
              onPressed: () => _onToggle(context, ref, false),
              icon: _icon,
              label: _label,
              style: _style(),
            )
          : OutlinedButton.icon(
              onPressed: () => _onToggle(context, ref, true),
              icon: _icon,
              label: _label,
              style: _style(
                foreground: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }

  /// Shared sizing so the button matches the 56px-tall Grid/Model dropdown
  /// fields beside it (measured), and doesn't inflate the row with the default
  /// 48px tap target.
  ButtonStyle _style({Color? foreground}) => ButtonStyle(
    foregroundColor: foreground == null
        ? null
        : WidgetStatePropertyAll(foreground),
    minimumSize: const WidgetStatePropertyAll(Size(0, 56)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
  );

  Future<void> _onToggle(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    // Read the notifier before any await so we never touch `ref`/`context`
    // across the async gap.
    final toggle = ref.read(codexAgentEnabledProvider.notifier);
    if (!value) {
      toggle.set(false);
      return;
    }
    if (ref.read(codexInstalledProvider)) {
      toggle.set(true);
      return;
    }
    final installed = await showCodexSetupDialog(context);
    if (installed ?? false) toggle.set(true);
  }
}
