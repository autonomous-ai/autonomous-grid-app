import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_version_service.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../agent/logic/hermes_tool.dart';
import '../logic/agent_catalog.dart';
import '../logic/agent_install_controller.dart';

/// The assistants this computer can run.
///
/// One today (Hermes, which answers your chats), and the ones that are coming.
/// The planned ones are listed but carry no controls — the screen says what it
/// will support without offering a button that would do nothing.
class AgentsView extends ConsumerWidget {
  const AgentsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionScaffold(
      title: 'Agents',
      subtitle:
          'The assistant that does the work: it runs on this computer, with '
          'your model, and can use your files and tools.',
      child: ListView.separated(
        itemCount: AgentTool.values.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) => _AgentCard(tool: AgentTool.values[i]),
      ),
    );
  }
}

class _AgentCard extends ConsumerWidget {
  const _AgentCard({required this.tool});

  final AgentTool tool;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Only Hermes can be installed today, so it's the only one whose presence is
    // worth probing — the rest are planned, and say so.
    final installed = tool.runnable && ref.watch(hermesInstalledProvider);

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.smart_toy_outlined,
                size: 20,
                color: tool.runnable
                    ? AppPalette.textPrimary
                    : AppPalette.textFaint,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          tool.name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _StatusChip(tool: tool, installed: installed),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tool.tagline,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Action(tool: tool, installed: installed),
            ],
          ),
          _Error(tool: tool),
        ],
      ),
    );
  }
}

/// Where the agent stands: answering chats, sitting there uninstalled, or not a
/// thing the app can run yet.
class _StatusChip extends ConsumerWidget {
  const _StatusChip({required this.tool, required this.installed});

  final AgentTool tool;
  final bool installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!tool.runnable) {
      return const _Chip(label: 'Not available yet', color: AppPalette.offline);
    }
    if (!installed) {
      return const _Chip(label: 'Not installed', color: AppPalette.offline);
    }
    // The version is a nice-to-have: an agent that won't say which build it is
    // still answers chats, so the chip must not wait on it.
    final version = ref.watch(hermesVersionProvider).asData?.value;
    final answering = tool == kChatAgent;
    return _Chip(
      label: [
        if (answering) 'Answers your chats' else 'Installed',
        if (version != null) 'v$version',
      ].join(' · '),
      color: AppPalette.brandBolt,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: color, size: 7),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// Install, or update what's there. A planned agent gets nothing — there is no
/// command behind it, and a disabled button would only look broken.
class _Action extends ConsumerWidget {
  const _Action({required this.tool, required this.installed});

  final AgentTool tool;
  final bool installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!tool.runnable) return const SizedBox.shrink();

    final state = ref.watch(agentInstallProvider);
    if (state is AgentInstallRunning && state.tool == tool) {
      return const _Working();
    }

    final controller = ref.read(agentInstallProvider.notifier);
    if (!installed) {
      return FilledButton(
        onPressed: () => controller.install(tool),
        child: const Text('Install'),
      );
    }
    return OutlinedButton(
      onPressed: () => controller.install(tool, upgrade: true),
      child: const Text('Update'),
    );
  }
}

/// It downloads, so it takes a moment — and says so instead of freezing a button.
class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 10),
        Text(
          'Installing…',
          style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
        ),
      ],
    );
  }
}

/// What went wrong, in the CLI's own last words — with the way to try again.
class _Error extends ConsumerWidget {
  const _Error({required this.tool});

  final AgentTool tool;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentInstallProvider);
    if (state is! AgentInstallFailed || state.tool != tool) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              state.message,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () =>
                ref.read(agentInstallProvider.notifier).install(tool),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
