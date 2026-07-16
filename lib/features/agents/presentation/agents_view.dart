import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_version_service.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
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

class _AgentCard extends ConsumerStatefulWidget {
  const _AgentCard({required this.tool});

  final AgentTool tool;

  @override
  ConsumerState<_AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends ConsumerState<_AgentCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    final tool = widget.tool;
    final theme = Theme.of(context);
    // Only Hermes can be installed today, so it's the only one whose presence is
    // worth probing — the rest are planned, and say so.
    final installed = tool.runnable && ref.watch(hermesInstalledProvider);

    final radius = BorderRadius.circular(16);
    // A planned agent reads as quieter: it can't be installed, so it shouldn't
    // invite a click the way the live one does. Only runnable rows lift on hover.
    final canHover = tool.runnable;
    final rim = canHover && _hovered
        ? tool.accent.withValues(alpha: 0.5)
        : AppGlass.hair;

    final card = MouseRegion(
      cursor: canHover ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: canHover ? (_) => setState(() => _hovered = true) : null,
      onExit: canHover ? (_) => setState(() => _hovered = false) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _hovered ? -2 : 0, 0),
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppCard.base,
          borderRadius: radius,
          border: Border.all(color: rim, width: 1.5),
          boxShadow: _hovered ? AppCard.shadow : AppGlass.cardShadow,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            children: [
              // The live agent leads: a faint diagonal wash in its own colour and
              // a soft corner glow lift it above the flat, planned rows below.
              if (tool.runnable)
                Positioned.fill(child: _AgentWash(color: tool.accent)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _AgentGlyph(tool: tool),
                        const SizedBox(width: 13),
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
                                      color: tool.runnable
                                          ? AppPalette.textPrimary
                                          : AppPalette.textSecondary,
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
              ),
            ],
          ),
        ),
      ),
    );

    // Fade the planned agents back so the one you can actually run leads.
    return AnimatedOpacity(
      opacity: tool.runnable ? 1 : 0.62,
      duration: const Duration(milliseconds: 160),
      child: card,
    );
  }
}

/// The wash behind the live agent's card: a faint diagonal tint in its own
/// colour that fades out toward the far corner, plus a soft glow anchored to the
/// top-right — the "hero" treatment that sets the running agent above the planned
/// ones. All low-opacity, so the text on top stays perfectly legible.
class _AgentWash extends StatelessWidget {
  const _AgentWash({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    color.withValues(alpha: 0.10),
                    color.withValues(alpha: 0.03),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 0.9],
                ),
              ),
            ),
          ),
          // Corner glow — a soft aura bleeding in from the top-right.
          Positioned(
            top: -70,
            right: -70,
            child: SizedBox(
              width: 200,
              height: 200,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    radius: 0.5,
                    colors: [color.withValues(alpha: 0.13), Colors.transparent],
                    stops: const [0.0, 0.85],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The agent's glyph in a soft chip tinted to its own colour — a point of focus
/// that tells the three rows apart and lifts them off the near-white pane.
class _AgentGlyph extends StatelessWidget {
  const _AgentGlyph({required this.tool});

  final AgentTool tool;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: tool.accent.withValues(alpha: tool.runnable ? 0.14 : 0.09),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(
        tool.icon,
        size: 20,
        color: tool.runnable ? tool.accent : tool.accent.withValues(alpha: 0.7),
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
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    if (!tool.runnable) {
      return _Chip(label: 'Not available yet', color: AppPalette.offline);
    }
    if (!installed) {
      return _Chip(label: 'Not installed', color: AppPalette.offline);
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
      // The live agent breathes — it's the one doing the work right now.
      pulsing: answering,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color, this.pulsing = false});

  final String label;
  final Color color;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: color, size: 7, pulsing: pulsing),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
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
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppSpinner(),
        const SizedBox(width: 10),
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
