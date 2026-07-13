import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
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

/// A compact install dialog driven by [AgentInstallController]. Hermes installs
/// in-app (the CLI fetches it — the user only waits); Codex hands `brew install`
/// to Terminal and re-checks on Continue.
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
            Text(_intro(info), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            _Body(state: state),
          ],
        ),
      ),
      actions: _actions(context, state, controller),
    );
  }

  /// What the user is agreeing to — honest about who does the work, and about
  /// the one flow that still needs them.
  String _intro(AgentToolInfo info) => switch (info.install) {
    GridCliInstall() =>
      '${info.blurb} It runs in the Chat tab, powered by your grid. Grid '
          'installs it for you — it takes a minute the first time.',
    BrewInstall(:final command) =>
      '${info.blurb} It runs in the Chat tab, powered by your grid. It '
          'installs once with Homebrew, in Terminal: $command',
  };

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
    // Nothing to press while the app installs — the only honest action is to
    // wait, so the dialog offers none.
    AgentSetupRunning() => const [],
    AgentSetupAwaitingTerminal() => [
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
      AgentSetupRunning() => const _InstallingLine(),
      AgentSetupAwaitingTerminal(:final note) => _Line(
        icon: Icons.terminal,
        color: theme.colorScheme.primary,
        text:
            note ?? 'Installing in Terminal. Press Continue when it finishes.',
      ),
      AgentSetupDone() => const _Line(
        icon: Icons.check_circle,
        color: AppPalette.online,
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

/// The app is doing the install itself. There is no meaningful percentage to
/// show (a package manager downloading dozens of things), so this says what is
/// happening and that it's normal for it to take a while — rather than a bare
/// spinner the user has to guess at.
class _InstallingLine extends StatelessWidget {
  const _InstallingLine();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Installing… this can take a minute the first time.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
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
