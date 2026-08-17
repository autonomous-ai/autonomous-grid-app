import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../features/agents/logic/agent_catalog.dart';
import '../../../features/agents/logic/agent_providers.dart';
import '../../../features/agents/logic/agent_step_label.dart';
import '../../../features/chat/logic/chat_sessions_controller.dart';
import '../../../features/chat/logic/working_chats.dart';
import '../../../features/playground/logic/chat_message.dart'
    show formatTurnDuration;
import '../../../features/projects/logic/project.dart';
import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icon_button.dart';
import '../../widgets/status_dot.dart';

/// One chat that is answering: press it to go there, or stop it where it stands.
///
/// A row of [WorkingNowPanel], in its own file because it is the half of that
/// panel with the moving parts — the live step, the clock, the hover state.
class WorkingNowRow extends ConsumerStatefulWidget {
  const WorkingNowRow({super.key, required this.chat, required this.onOpen});

  /// The chat this row is about, as "Working now" derived it.
  final WorkingChat chat;

  /// Go to it — the panel's own handler, which closes the popover first.
  final VoidCallback onOpen;

  @override
  ConsumerState<WorkingNowRow> createState() => _WorkingNowRowState();
}

class _WorkingNowRowState extends ConsumerState<WorkingNowRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final chat = widget.chat;
    final project = ref.watch(projectByIdProvider(chat.projectId));
    final agent = agentToolById(chat.agentId);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: widget.onOpen,
        borderRadius: BorderRadius.circular(8),
        hoverColor: AppSurface.hoverFill,
        splashFactory: NoSplash.splashFactory,
        onHover: (value) => setState(() => _hovered = value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              // Pulsing, unlike the sidebar's static cue: this list is opened to
              // be read for a few seconds, not scanned past.
              StatusDot(color: AppPalette.online, size: 6, pulsing: true),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: AppFont.medium,
                        color: AppPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _RowDetail(
                      chatId: chat.id,
                      place: project?.name,
                      agent: agent?.name,
                      queued: chat.queued,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _Elapsed(startedAt: chat.startedAt),
              const SizedBox(width: 2),
              // Kept in the layout at rest so the row doesn't reflow under the
              // pointer — only its ink comes up on hover. Dead while invisible
              // too: an [Opacity] of zero still takes the click, and a stop the
              // user cannot see must not be one they can press by accident.
              Opacity(
                opacity: _hovered ? 1 : 0,
                child: AppIconButton(
                  icon: LucideIcons.circleStop300,
                  size: 14,
                  tooltip: 'Stop this chat',
                  onPressed: _hovered
                      ? () => ref
                            .read(chatSessionsProvider.notifier)
                            .stopChat(chat.id)
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quiet line under a working chat's name: where it is running, who is
/// answering, and what that agent is doing this second.
///
/// Its own widget because the step changes every few seconds and nothing else in
/// the row does — watching the run feed from the row itself would redraw the
/// title, the clock and the stop with it.
class _RowDetail extends ConsumerWidget {
  const _RowDetail({
    required this.chatId,
    required this.place,
    required this.agent,
    required this.queued,
  });

  final String chatId;

  /// The project's name, or null for a chat outside every project.
  final String? place;

  /// The agent answering, or null when the grid itself is.
  final String? agent;

  final int queued;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final detail = ref.watch(chatPrefsProvider.select((p) => p.detail));
    final step = ref.watch(
      agentRunProvider(chatId).select((run) => _runningStep(run.steps)),
    );
    final parts = <String>[
      place ?? 'Chats',
      ?agent,
      // At "Answer only" the user has asked not to be shown the machinery, and
      // this panel is not the place to overrule that.
      if (step != null && detail != AgentDetailMode.answer)
        agentStepLabel(step, detail)
      else if (agent != null)
        'Thinking…'
      else
        'Answering…',
      if (queued > 0) '$queued waiting',
    ];
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: AppPalette.textFaint),
    );
  }
}

/// The step the turn is waiting on, or null while it composes the next one.
///
/// The *last* running step, the same rule the chat's own feed follows: a step
/// that starts a sub-agent stays running while the work it delegated goes on, so
/// the newest is the one actually happening.
AgentActivity? _runningStep(List<AgentActivity> steps) {
  AgentActivity? running;
  for (final step in steps) {
    if (step.status == AgentActivityStatus.running) running = step;
  }
  return running;
}

/// How long this turn has been going, counting up while the panel is open.
///
/// Its own ticker rather than a clock provider: nothing outside this panel needs
/// a second hand, and a timer that only exists while the popover is open costs
/// nothing the rest of the time.
class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.startedAt});

  final DateTime? startedAt;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final startedAt = widget.startedAt;
    // A turn between being committed and dispatched has no start time yet; it
    // has by the next tick, and a blank is better than a zero that would read as
    // a stalled clock.
    final label = startedAt == null
        ? ''
        : formatTurnDuration(DateTime.now().difference(startedAt));
    return Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        color: AppPalette.textSecondary,
        fontFeatures: AppFont.tabularFigures,
      ),
    );
  }
}
