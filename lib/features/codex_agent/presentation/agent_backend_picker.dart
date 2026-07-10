import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/agent_backend.dart';
import '../logic/agent_tool.dart';
import 'agent_setup_dialog.dart';

/// The Chat-tab control that picks the agent backend: Off (normal chat), Codex,
/// or Hermes. Selecting a backend whose tool isn't installed opens the one-time
/// setup and only switches once that succeeds.
///
/// Rendered as a dropdown-style button 56px tall so it lines up with the
/// Grid/Model fields; the on-state fills blue with `onPrimary` (white) content
/// for legible contrast.
class AgentBackendPicker extends ConsumerWidget {
  const AgentBackendPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(agentBackendProvider);
    return MenuAnchor(
      menuChildren: [
        for (final option in AgentBackend.values)
          MenuItemButton(
            leadingIcon: Icon(
              backend == option ? Icons.check : Icons.smart_toy_outlined,
              size: 18,
            ),
            onPressed: () => _select(context, ref, option),
            child: Text(option == AgentBackend.off ? 'Off' : option.label),
          ),
      ],
      builder: (context, controller, _) => _PickerButton(
        backend: backend,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    AgentBackend backend,
  ) async {
    // Read the notifier before any await so we never touch `ref` across the gap.
    final controller = ref.read(agentBackendProvider.notifier);
    final tool = backend.tool;
    if (tool == null) {
      controller.set(AgentBackend.off);
      return;
    }
    if (ref.read(agentToolInstalledProvider(tool))) {
      controller.set(backend);
      return;
    }
    final installed = await showAgentSetupDialog(context, tool);
    if (installed ?? false) controller.set(backend);
  }
}

/// The button face: a robot icon, the current backend's label, and a dropdown
/// caret. Filled (blue) when a backend is on, outlined when off.
class _PickerButton extends StatelessWidget {
  const _PickerButton({required this.backend, required this.onTap});

  final AgentBackend backend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(backend.label),
        const Icon(Icons.arrow_drop_down, size: 20),
      ],
    );
    const icon = Icon(Icons.smart_toy_outlined, size: 18);
    return Tooltip(
      message:
          'Agent (experimental): run this chat through Codex or Hermes, '
          "using your grid's model.",
      child: backend.isOn
          ? FilledButton.icon(
              onPressed: onTap,
              icon: icon,
              label: label,
              style: _style(),
            )
          : OutlinedButton.icon(
              onPressed: onTap,
              icon: icon,
              label: label,
              style: _style(
                foreground: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }

  /// Compact sizing so it reads as a light floating pill, not a full-height
  /// form field.
  ButtonStyle _style({Color? foreground}) => ButtonStyle(
    foregroundColor: foreground == null
        ? null
        : WidgetStatePropertyAll(foreground),
    minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
  );
}
