import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/codex_install_controller.dart';

/// Opens the one-time Codex install flow. Resolves to true when codex ends up
/// installed (so the caller can turn Agent mode on), false/null otherwise.
Future<bool?> showCodexSetupDialog(BuildContext context) => showDialog<bool>(
  context: context,
  builder: (_) => const _CodexSetupDialog(),
);

/// A compact install dialog driven by [CodexInstallController]: explain what
/// Agent mode is, hand off `brew install --cask codex` to Terminal, then
/// re-check on Continue — the same visible-checklist shape as the engine setup.
class _CodexSetupDialog extends ConsumerWidget {
  const _CodexSetupDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(codexInstallControllerProvider);
    final controller = ref.read(codexInstallControllerProvider.notifier);
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Turn on Agent mode'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Agent is an assistant powered by Codex — it can read files and '
              'run read-only tasks in a dedicated folder. It needs Codex '
              'installed once, via Homebrew.',
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
    CodexSetupState state,
    CodexInstallController controller,
  ) => switch (state) {
    CodexSetupIdle() => [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Later'),
      ),
      FilledButton(
        onPressed: controller.run,
        child: const Text('Install Codex'),
      ),
    ],
    CodexSetupInstalling() => [
      TextButton(
        onPressed: controller.reopenTerminal,
        child: const Text('Reopen Terminal'),
      ),
      FilledButton(
        onPressed: controller.continueSetup,
        child: const Text('Continue'),
      ),
    ],
    CodexSetupDone() => [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Done'),
      ),
    ],
    CodexSetupFailed() => [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Close'),
      ),
      FilledButton(onPressed: controller.run, child: const Text('Try again')),
    ],
  };
}

/// The state-specific line under the explanation.
class _Body extends StatelessWidget {
  const _Body({required this.state});

  final CodexSetupState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (state) {
      CodexSetupIdle() => const SizedBox.shrink(),
      CodexSetupInstalling(:final note) => _Line(
        icon: Icons.terminal,
        color: theme.colorScheme.primary,
        text:
            note ?? 'Installing in Terminal. Press Continue when it finishes.',
      ),
      CodexSetupDone() => _Line(
        icon: Icons.check_circle,
        color: Colors.green,
        text: 'Codex is installed. Agent is ready.',
      ),
      CodexSetupFailed(:final message) => _Line(
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
