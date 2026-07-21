import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/status_dot.dart';
import '../logic/active_chat_agent.dart';
import '../logic/agent_catalog.dart';
import '../logic/agent_install_controller.dart';
import '../logic/agent_status.dart';

/// The assistants this computer can run — Hermes and Codex today, one of which
/// answers your chats.
///
/// This is a status list, not a gallery: quiet rows read once in a while to check
/// a version, pull an update, or hand the chat to a different agent. So it wears
/// the same surface as Plugins and Scheduled — except the agent answering chats,
/// which wears the brand (a gold rim and a filled "Answers your chats" badge) so
/// it's obvious at a glance which one is live.
///
/// Only agents the app can install are listed. A "coming soon" row costs a
/// first-time user the same read as a working one and gives nothing back.
class AgentsView extends ConsumerWidget {
  const AgentsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionScaffold(
      title: 'Agents',
      subtitle:
          'The assistant that does the work: it runs on this computer, with '
          'your model, and can use your files and tools.',
      // Name on the left, action on the right. Let a row run the full width of a
      // large window and the two ends drift apart until pairing them takes a
      // deliberate look; this keeps a row scannable in one glance. Matches the
      // width Plugins bounds its rows to.
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 940),
          child: ListView.separated(
            itemCount: AgentTool.values.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _AgentCard(tool: AgentTool.values[i]),
          ),
        ),
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
    // Each row probes its own agent, so it reads its own state.
    final installed = ref.watch(agentInstalledProvider(tool));

    // The agent answering chats right now wears the brand: a gold rim and a faint
    // gold wash lift it out of the quiet list so it's obvious which one is live.
    final isActive = installed && tool == ref.watch(activeChatAgentProvider);
    final baseFill = _hovered
        ? AppGlass.surfaceHoverFill
        : AppGlass.surfaceFill;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        // The house row-hover timing, shared with the plugin and job lists.
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: isActive
              ? Color.alphaBlend(
                  AppPalette.brandBolt.withValues(alpha: 0.08),
                  baseFill,
                )
              : baseFill,
          borderRadius: BorderRadius.circular(14),
          border: isActive
              ? Border.all(
                  color: AppPalette.brandBolt.withValues(alpha: 0.55),
                  width: 1.5,
                )
              : null,
          boxShadow: AppGlass.cardShadow,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AgentGlyph(tool: tool),
                  const SizedBox(width: 11),
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
                                color: AppPalette.textPrimary,
                              ),
                            ),
                            const SizedBox(width: 10),
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
      ),
    );
  }
}

/// The agent's own mark — the thing that tells the three rows apart at a glance.
///
/// Drawn as the image itself, not tinted into a chip the way the plugin list
/// does: those are one repeated glyph that needs colour to mean anything, while
/// these are real logos that already carry their own. A tint well behind them
/// would only stack a second backdrop under the one each already has.
///
/// A few pixels larger than the plugin list's icon well, which holds a flat
/// one-colour glyph that reads fine small. These are detailed artwork — a face,
/// a robot — and at 30 they turn to mush before they turn into a logo.
class _AgentGlyph extends StatelessWidget {
  const _AgentGlyph({required this.tool});

  static const _size = 34.0;

  final AgentTool tool;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        // Several of these marks sit on their own solid backdrop — Hermes' is
        // white — which would float shapelessly against the dark theme's
        // charcoal. A hairline gives every one of them an edge to end on.
        border: Border.all(color: AppGlass.hair),
      ),
      child: ClipRRect(
        // Inset by the border so the image doesn't paint over the hairline.
        borderRadius: BorderRadius.circular(9),
        child: Image.asset(
          tool.iconAsset,
          width: _size,
          height: _size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

/// Where the agent stands: answering chats, or sitting there uninstalled.
class _StatusChip extends ConsumerWidget {
  const _StatusChip({required this.tool, required this.installed});

  final AgentTool tool;
  final bool installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    if (!installed) {
      return _Chip(label: 'Not installed', color: AppPalette.offline);
    }
    // The version is a nice-to-have: an agent that won't say which build it is
    // still answers chats, so the chip must not wait on it.
    final version = ref.watch(agentVersionProvider(tool)).asData?.value;
    final answering = tool == ref.watch(activeChatAgentProvider);
    return _Chip(
      label: [
        if (answering) 'Answers your chats' else 'Installed',
        if (version != null) 'v$version',
      ].join(' · '),
      color: AppPalette.brandBolt,
      // The live agent breathes — it's the one doing the work right now — and
      // wears a filled brand pill so "Answers your chats" reads as its state.
      pulsing: answering,
      filled: answering,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.color,
    this.pulsing = false,
    this.filled = false,
  });

  final String label;
  final Color color;
  final bool pulsing;

  /// A filled brand pill instead of plain dot + text — for the agent answering
  /// chats, so its badge stands out as a state rather than a quiet footnote.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: color, size: 7, pulsing: pulsing),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: filled ? color : AppPalette.textSecondary,
          ),
        ),
      ],
    );
    if (!filled) return row;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: row,
    );
  }
}

/// Install, or update what's there.
class _Action extends ConsumerWidget {
  const _Action({required this.tool, required this.installed});

  final AgentTool tool;
  final bool installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    // With a second agent installed, the one that isn't answering chats offers
    // to take over — the active one already says so in its status chip, so it
    // needs no button. One agent installed → it's always active, no choice shown.
    final isActive = ref.watch(activeChatAgentProvider) == tool;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isActive) ...[
          TextButton(
            onPressed: () =>
                ref.read(chatPrefsProvider.notifier).setChatAgent(tool.id),
            child: const Text('Use for chat'),
          ),
          const SizedBox(width: 4),
        ],
        OutlinedButton(
          onPressed: () => controller.install(tool, upgrade: true),
          child: const Text('Update'),
        ),
      ],
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
