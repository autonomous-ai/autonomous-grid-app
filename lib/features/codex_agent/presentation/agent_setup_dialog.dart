import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/agent_install_controller.dart';
import '../logic/agent_tool.dart';

/// Opens the one-time install flow for [tool]. Resolves to true when the tool
/// ends up installed (so the caller can select that backend), false/null
/// otherwise.
Future<bool?> showAgentSetupDialog(BuildContext context, AgentTool tool) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _AgentSetupDialog(tool: tool),
    );

/// A compact install dialog driven by [AgentInstallController]: explain what the
/// tool is, hand off `brew install …` to Terminal, then re-check on Continue.
class _AgentSetupDialog extends ConsumerWidget {
  const _AgentSetupDialog({required this.tool});

  final AgentTool tool;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentInstallControllerProvider);
    final controller = ref.read(agentInstallControllerProvider.notifier);
    final info = kAgentTools[tool]!;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text('Set up ${info.displayName}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${info.blurb} It runs in the Chat tab, powered by your grid. It '
              'needs installing once via Homebrew.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _Body(state: state),
          ],
        ),
      ),
      actions: _actions(context, state, controller),
    );
  }

  List<Widget> _actions(
    BuildContext context,
    AgentSetupState state,
    AgentInstallController controller,
  ) => switch (state) {
    AgentSetupIdle() => [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Later'),
      ),
      FilledButton(
        onPressed: () => controller.start(tool),
        child: const Text('Install'),
      ),
    ],
    AgentSetupInstalling() => [
      TextButton(
        onPressed: controller.reopenTerminal,
        child: const Text('Reopen Terminal'),
      ),
      FilledButton(
        onPressed: controller.continueSetup,
        child: const Text('Continue'),
      ),
    ],
    AgentSetupDone() => [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Done'),
      ),
    ],
    AgentSetupFailed() => [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Close'),
      ),
      FilledButton(
        onPressed: () => controller.start(tool),
        child: const Text('Try again'),
      ),
    ],
  };
}

/// The state-specific line under the explanation.
class _Body extends StatelessWidget {
  const _Body({required this.state});

  final AgentSetupState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (state) {
      AgentSetupIdle() => const SizedBox.shrink(),
      AgentSetupInstalling(:final note) => _Line(
        icon: Icons.terminal,
        color: theme.colorScheme.primary,
        text:
            note ?? 'Installing in Terminal. Press Continue when it finishes.',
      ),
      AgentSetupDone() => const _Line(
        icon: Icons.check_circle,
        color: Colors.green,
        text: 'Installed. The agent is ready.',
      ),
      AgentSetupFailed(:final message) => _Line(
        icon: Icons.error_outline,
        color: theme.colorScheme.error,
        text: message,
      ),
    };
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}
