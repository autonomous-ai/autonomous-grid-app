/// The orchestration overview — how this chat is being routed and how far its
/// turn has got — shown as a floating panel that hangs off the top bar's
/// workflow button (a relative popover, the same family as the grid power /
/// stat panels), never as an element pushed into the conversation.
///
/// **It reuses [openTurnModelsProvider]** — the poll `TurnModelUsage` already
/// runs for every open turn (`chat_sessions_send.dart` calls `begin` as the
/// turn goes out and `end` when it settles) — rather than opening a second one.
/// A second poll would have to repeat that whole file: a timer per chat, the
/// `ref.mounted` guards across the wire, the rule that a 404 from a grid whose
/// master predates `/relay/v1/usage` reads as "no data yet" and never as an
/// error, and start/stop hooks in the sender. One panel is not worth two of
/// those.
///
/// What that buys, and what it does **not**:
///
/// - It answers *which model ids the grid has credited with work* since this
///   turn opened. That is enough to move a node off "queued".
/// - It cannot separate a model that has finished from one still mid-request —
///   the usage log counts requests, it does not report their state. So a
///   credited model reads as [NodeStatus.running] while the turn is open and
///   [NodeStatus.done] once it has landed, and the panel says as much in words
///   rather than implying a precision it hasn't got.
/// - It cannot see a **round**, so this panel never claims "round 2 of 5"; and
///   it cannot see a judge's verdict, so [NodeStatus.rejected] is never shown.
///   Naming either would be inventing it.
/// - Mid-turn the reading is time-window correlated, so two turns running at
///   once on one grid blend into each other's numbers — the trade-off
///   `TurnModelUsage` documents and accepts. Once the turn lands this panel
///   switches to the *exact* conversation-scoped slice stored on the message
///   (`ChatMessage.orchestrationModels`), which has no such blending.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/widgets/pill_panel_shell.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';
import '../logic/routing_group.dart';
import '../logic/turn_model_share.dart';
import '../logic/turn_model_usage.dart';
import 'orchestration_node_diagram.dart';

/// The widest fan-out a Brute Force turn can run, matching the relay's own
/// `MAX_N`. Only ever applied to a shape read off the usage log — a group that
/// names its models is drawn exactly as it was saved.
const int _kMaxNodes = 4;

/// The panel's width cap, so the wide Brute Force fan-out diagram shrinks to
/// fit rather than spilling past the screen edge.
const double _kMaxWidth = 620;

/// The panel content for a routed chat, hosted by the top bar's workflow
/// popover. Draws nothing for a chat on the grid's ordinary pick (no group) or
/// with no conversation open.
class WorkflowFlowPanel extends ConsumerWidget {
  const WorkflowFlowPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final conversation = ref.watch(
      chatSessionsProvider.select((s) => s.active),
    );
    final group = conversation?.routingGroup;
    if (conversation == null || group == null) return const SizedBox.shrink();

    // Whether this chat has a turn in flight, not "the app is busy".
    final inFlight = ref.watch(
      chatSessionsProvider.select((s) => s.sendingFor(conversation.id)),
    );
    // Live while the turn runs, then the exact conversation-scoped slice the
    // landed message carries. See this file's header for why those are two
    // different readings of one question.
    final shares = inFlight
        ? ref.watch(openTurnModelsProvider(conversation.id))
        : _settledShares(conversation);
    final flow = _resolve(group, shares, inFlight: inFlight);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _kMaxWidth),
      child: _FlowCard(flow: flow),
    );
  }
}

/// What the last answered turn was credited with — the exact
/// conversation-scoped slice when the settle read landed, and the live poll's
/// own last reading when it didn't (a grid whose master predates the endpoint).
List<ModelShare> _settledShares(Conversation conversation) {
  for (final message in conversation.messages.reversed) {
    if (message.role != ChatRole.assistant) continue;
    return message.orchestrationModels ?? message.modelShares;
  }
  return const [];
}

/// One chat's flow as this panel can currently describe it: the header's status
/// line and the nodes it draws expanded.
///
/// [nodes] is null when the reading is too thin to draw a shape from — a
/// Dynamic group before its first model has answered. A diagram built from no
/// data would be a picture of a guess.
///
/// [pinnedShape] says where the node *order* came from: a group that names its
/// models (Fixed) puts each one in its own place, while a shape read back off
/// the usage log only knows *that* these models worked, never which of them
/// took which part. The panel's footnote changes accordingly — the diagram has
/// no role labels, but its layout implies them, and implying one we can't
/// support is exactly the kind of confident wrongness §5 rules out.
typedef _Flow = ({
  RoutingGroup group,
  String status,
  Widget? nodes,
  bool pinnedShape,
});

/// Everything the panel needs, derived from [group] and whatever the grid has
/// credited so far in [shares].
_Flow _resolve(
  RoutingGroup group,
  List<ModelShare> shares, {
  required bool inFlight,
}) {
  final ranked = rankedShares(shares);
  final served = {for (final s in ranked) s.model.trim().toLowerCase()};
  final pinned = _pinnedIds(group);
  // Capped on the way in, only on the path that isn't pinned: a Dynamic
  // group's nodes are whatever the window caught, and that window can catch a
  // neighbouring turn's models too (see this file's header). Four is the widest
  // fan-out the grid itself will run, so a fifth pill is noise from another turn
  // rather than news about this one.
  final ids =
      pinned ?? [for (final s in ranked) s.model].take(_kMaxNodes).toList();
  return (
    group: group,
    // Counted against the models this group named, never against every model
    // the window caught: a grid free to pick its own aggregator can credit a
    // model that isn't in a Fixed group at all, and "4 of 3 answered" is a
    // sentence no reader forgives.
    status: _statusLine(
      served: pinned == null ? served.length : _countIn(pinned, served),
      total: pinned?.length,
      inFlight: inFlight,
    ),
    nodes: _diagram(group, ids, served, inFlight: inFlight),
    pinnedShape: pinned != null,
  );
}

/// How many distinct ids of [pinned] appear in [served].
int _countIn(List<String> pinned, Set<String> served) => {
  for (final id in pinned) id.trim().toLowerCase(),
}.where(served.contains).length;

/// The model ids this group pins, or null when the grid re-picks them every
/// turn (Dynamic) — or when a saved group is too short to draw the shape it
/// claims, which reads the same way here: we don't know, ask the turn.
List<String>? _pinnedIds(RoutingGroup group) {
  if (!group.isFixed) return null;
  return switch (group.mode) {
    RoutingMode.bruteForce =>
      (group.models?.length ?? 0) >= 2 ? group.models : null,
    RoutingMode.judgeLoop => switch ((group.worker, group.judge)) {
      (final String worker, final String judge) => [worker, judge],
      _ => null,
    },
  };
}

/// The one-line status: how much of this turn the grid has accounted for.
///
/// A count, never a round and never a verdict — see this file's header for what
/// the usage log can and cannot say.
String _statusLine({
  required int served,
  required int? total,
  required bool inFlight,
}) {
  if (served == 0) return inFlight ? 'starting' : 'nothing has run yet';
  final counted = total == null
      ? '$served ${served == 1 ? 'model' : 'models'}'
      : '$served of $total';
  return inFlight ? '$counted answered so far' : '$counted answered';
}

/// The node diagram for [ids] in [group]'s shape, or null when [ids] is too
/// short to draw one.
Widget? _diagram(
  RoutingGroup group,
  List<String> ids,
  Set<String> served, {
  required bool inFlight,
}) {
  if (ids.length < 2) return null;
  DiagramNode node(String id) =>
      DiagramNode(id, _statusOf(id, served, inFlight: inFlight));
  return switch (group.mode) {
    // The last model stands in for the aggregator as well as fanning out as a
    // proposer — the same stand-in the setup dialog's preview uses, and for the
    // reason documented there: a group names its proposer set and never a
    // separate aggregator, and which model aggregates is the grid's own call.
    RoutingMode.bruteForce => OrchestrationNodeDiagram.bruteForce(
      you: _kYou,
      proposers: [for (final id in ids) node(id)],
      aggregator: node(ids.last),
      answer: _kAnswer,
    ),
    RoutingMode.judgeLoop => OrchestrationNodeDiagram.judgeLoop(
      you: _kYou,
      worker: node(ids.first),
      judge: node(ids[1]),
      answer: _kAnswer,
    ),
  };
}

/// The two ends of every diagram — the question and the reply, not steps that
/// run, which is why [OrchestrationNodeDiagram] draws them with no status dot.
const DiagramNode _kYou = DiagramNode('You', NodeStatus.queued);
const DiagramNode _kAnswer = DiagramNode('Answer', NodeStatus.queued);

/// How far along one node is, as far as the usage log can tell.
///
/// Credited with work while the turn is open → running; credited once it has
/// landed → done; not credited → queued. [NodeStatus.rejected] is never
/// returned: nothing the app can read reports a judge's verdict, and a warning
/// colour on a guess is worse than no colour at all.
NodeStatus _statusOf(String id, Set<String> served, {required bool inFlight}) {
  if (!served.contains(id.trim().toLowerCase())) return NodeStatus.queued;
  return inFlight ? NodeStatus.running : NodeStatus.done;
}

/// The panel's body: the mode/status header, the node diagram, and the footnote
/// that says what a lit dot does and does not mean.
class _FlowCard extends StatelessWidget {
  const _FlowCard({required this.flow});

  final _Flow flow;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return PillPanelSurface(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _PanelHeader(flow: flow),
            const SizedBox(height: 6),
            if (flow.nodes case final diagram?) ...[
              // A wide Brute Force fan-out is ~660px against this panel's ~620px
              // cap — shrink to fit rather than spill off the screen.
              FittedBox(fit: BoxFit.scaleDown, child: diagram),
              const SizedBox(height: 4),
              // Said out loud rather than left to the dots to imply: the usage
              // log counts requests, so a lit dot cannot mean what a reader
              // would take it to mean unaided.
              PillPanelMessage(text: _footnote(flow)),
            ] else
              PillPanelMessage(text: _emptyLine(flow.group)),
          ],
        ),
      ),
    );
  }
}

/// The line under the diagram: what a lit dot does and does not mean.
///
/// Two versions, because a shape read off the usage log knows less than a
/// pinned one does — see [_Flow.pinnedShape].
String _footnote(_Flow flow) => flow.pinnedShape
    ? 'A lit model is one the grid has credited with work in this turn.'
    : 'The grid picks these for each message. A lit model is one it has '
          'credited with work in this turn; which one took which part is not '
          'reported back.';

/// What the panel says when it has no nodes to draw — never a blank box, and
/// never a diagram of models nobody has named yet.
String _emptyLine(RoutingGroup group) => group.isFixed
    ? 'This chat is pinned to a routing mode, but no models were saved with '
          'it. Pick the mode again to choose them.'
    : 'The grid picks the models for each message. They appear here as soon '
          'as the first one answers.';

/// The panel's first line: the mode, whether its models repeat, and the same
/// status the header carries.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.flow});

  final _Flow flow;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Icon(LucideIcons.workflow, size: 13, color: AppPalette.textFaint),
        const SizedBox(width: 7),
        Text(
          flow.group.mode.displayName,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: AppFont.medium,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            flow.status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
          ),
        ),
      ],
    );
  }
}
