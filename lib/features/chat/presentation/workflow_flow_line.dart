/// Where this view's live status comes from — decided before it was written,
/// because it decides the whole shape of the widget below.
///
/// **It reuses [openTurnModelsProvider]** — the poll `TurnModelUsage` already
/// runs for every open turn (`chat_sessions_send.dart` calls `begin` as the
/// turn goes out and `end` when it settles) — rather than opening a second one.
/// A second poll would have to repeat that whole file: a timer per chat, the
/// `ref.mounted` guards across the wire, the rule that a 404 from a grid whose
/// master predates `/relay/v1/usage` reads as "no data yet" and never as an
/// error, and start/stop hooks in the sender. One caption is not worth two of
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
/// - It cannot see a **round**, so this view never claims "round 2 of 5"; and
///   it cannot see a judge's verdict, so [NodeStatus.rejected] is never shown.
///   Naming either would be inventing it.
/// - Mid-turn the reading is time-window correlated, so two turns running at
///   once on one grid blend into each other's numbers — the trade-off
///   `TurnModelUsage` documents and accepts. Once the turn lands this view
///   switches to the *exact* conversation-scoped slice stored on the message
///   (`ChatMessage.orchestrationModels`), which has no such blending.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/widgets/pill_panel_shell.dart';
import '../../../shared/layouts/widgets/top_bar_pill.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';
import '../logic/routing_group.dart';
import '../logic/turn_model_share.dart';
import '../logic/turn_model_usage.dart';
import '../logic/workflow_bubble_open.dart';
import 'orchestration_node_diagram.dart';

/// The strip above the conversation saying how this chat is being routed and
/// how far its turn has got — and, on hover or held open by a click, the same
/// node diagram the routing setup dialog previews, driven by the live turn.
///
/// Draws nothing at all for a chat on the grid's ordinary pick: the whole
/// feature is about a [RoutingGroup], and a bar reporting "no orchestration" on
/// every other chat would be chrome that never says anything.
class WorkflowFlowLine extends ConsumerStatefulWidget {
  const WorkflowFlowLine({super.key, required this.conversation});

  /// The open conversation, or null before one is chosen.
  final Conversation? conversation;

  @override
  ConsumerState<WorkflowFlowLine> createState() => _WorkflowFlowLineState();
}

/// How long the pointer must rest on the strip before the diagram opens, and
/// how long it may be off it before the diagram closes.
///
/// The same two beats `GridPowerPill` uses, for the same two reasons: the wait
/// is so a pointer crossing the top of the chat on its way elsewhere doesn't
/// flash a panel open behind it, and the grace is so the pointer can cross the
/// gap between the strip and the panel without it closing underfoot.
const Duration _kOpenDelay = Duration(milliseconds: 180);
const Duration _kCloseGrace = Duration(milliseconds: 120);

/// The widest fan-out a Brute Force turn can run, matching the relay's own
/// `MAX_N`. Only ever applied to a shape read off the usage log — a group that
/// names its models is drawn exactly as it was saved.
const int _kMaxNodes = 4;

class _WorkflowFlowLineState extends ConsumerState<WorkflowFlowLine> {
  final _link = LayerLink();
  final _controller = OverlayPortalController();

  /// Ties the strip and its panel into one tap region, so a click inside either
  /// isn't the "click outside" that dismisses a pinned panel.
  final _tapGroup = Object();

  /// Whether the pointer is on the strip or on the panel it opened. Set on
  /// entry *before* the previous exit's delayed close runs, which is what lets
  /// the pointer travel from one to the other without the panel blinking.
  bool _hovered = false;

  /// Held open by a click rather than by the pointer resting on the strip.
  ///
  /// Hover alone can't be read from here: the diagram is wide enough to scroll
  /// sideways, and a panel that shuts the moment the pointer leaves the strip
  /// can't be scrolled at all.
  bool _pinned = false;

  @override
  void initState() {
    super.initState();
    // The top bar's workflow toggle is a standing "keep this open", so a chat
    // opened while it is on starts pinned. Deferred one frame: the portal isn't
    // mounted until this state has built once, and showing a controller with
    // nothing attached asserts.
    if (!ref.read(workflowBubbleOpenProvider)) return;
    _pinned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pinned && _routing != null) _open();
    });
  }

  @override
  void didUpdateWidget(covariant WorkflowFlowLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_routing != null || !_controller.isShowing) return;
    // Switching to a chat on the grid's ordinary pick unmounts the portal. Let
    // go of it, or a later remount would come back already open — but not from
    // here: this runs inside the frame's build, and hiding marks the portal
    // dirty. One frame later it is detached, where hiding is just bookkeeping.
    _pinned = false;
    _hovered = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _routing == null) _shut();
    });
  }

  /// This chat's routing group, or null when there is nothing to draw.
  RoutingGroup? get _routing => widget.conversation?.routingGroup;

  void _open() {
    if (!_controller.isShowing) _controller.show();
  }

  void _shut() {
    if (_controller.isShowing) _controller.hide();
  }

  /// Let the panel go and forget it was ever held — what a second click, a
  /// click outside, and the top bar's toggle turning off all mean.
  void _release() {
    if (!_pinned) {
      _shut();
      return;
    }
    setState(() => _pinned = false);
    _shut();
  }

  void _onEnter() {
    _hovered = true;
    if (_controller.isShowing) return;
    Future<void>.delayed(_kOpenDelay, () {
      if (mounted && _hovered && _routing != null) _open();
    });
  }

  void _onExit() {
    _hovered = false;
    Future<void>.delayed(_kCloseGrace, () {
      if (!mounted || _hovered || _pinned) return;
      _shut();
    });
  }

  /// A click pins the panel open, so it can be read and scrolled without the
  /// pointer having to stay put; a second click lets it go.
  void _toggle() {
    if (_pinned) {
      _release();
      return;
    }
    setState(() => _pinned = true);
    _open();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // The top bar's toggle, given a job here rather than left to mean nothing:
    // it is the one control that says "show me the orchestration", so it pins
    // and unpins this panel. Hover still opens it transiently either way.
    ref.listen(workflowBubbleOpenProvider, (_, open) {
      if (_routing == null) return;
      if (!open) {
        _release();
        return;
      }
      if (_pinned) return;
      setState(() => _pinned = true);
      _open();
    });

    final conversation = widget.conversation;
    final group = _routing;
    if (conversation == null || group == null) return const SizedBox.shrink();

    // Whether *this* chat has a turn in flight, not "the app is busy": a turn
    // dispatched into another conversation must not set this one's nodes going.
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

    // Hugging its content and left-aligned: this is a capsule floating over the
    // top of the conversation, the way the top bar's own pills float over it —
    // not a bar, which would put a second rule under the one the top bar
    // already draws below the chat's title.
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _onEnter(),
          onExit: (_) => _onExit(),
          child: TapRegion(
            groupId: _tapGroup,
            onTapOutside: (_) {
              if (_pinned) _release();
            },
            child: CompositedTransformTarget(
              link: _link,
              child: OverlayPortal(
                controller: _controller,
                overlayChildBuilder: (context) => _FlowPanel(
                  link: _link,
                  tapGroupId: _tapGroup,
                  flow: flow,
                  onEnter: _onEnter,
                  onExit: _onExit,
                ),
                child: Semantics(
                  label: _spoken(flow),
                  button: true,
                  container: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggle,
                    child: TopBarPill(child: _CollapsedRow(flow: flow)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A spoken summary — the panel is pointer-driven, so what it shows has to be
/// reachable from the strip itself.
String _spoken(_Flow flow) => [
  'Routing: ${flow.group.mode.displayName}',
  flow.group.isFixed
      ? 'the same models every message'
      : 'models re-picked every message',
  flow.status,
].join(', ');

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

/// One chat's flow as this view can currently describe it: the line the strip
/// shows collapsed, and the nodes the panel draws expanded.
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

/// Everything the strip and the panel need, derived from [group] and whatever
/// the grid has credited so far in [shares].
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

/// The strip itself: how this chat is routed, and how far its turn has got.
class _CollapsedRow extends StatelessWidget {
  const _CollapsedRow({required this.flow});

  final _Flow flow;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.workflow, size: 13, color: AppPalette.textFaint),
        const SizedBox(width: 7),
        Text(
          flow.group.mode.displayName,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(width: 7),
        // Bounded rather than Expanded: the strip hugs its own content — it is
        // a capsule, not a bar — so a long status has to ellipsize instead of
        // widening the capsule past the edge of a narrow window.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(
            flow.status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
          ),
        ),
        const SizedBox(width: 4),
        Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 14,
          color: AppPalette.textFaint,
        ),
      ],
    );
  }
}

/// The panel the strip opens: this turn drawn as nodes.
///
/// Hung under the strip on the glass surface every hover panel in this app
/// already uses ([PillPanelSurface]), so a popover opening from the chat's own
/// chrome reads as one family with the ones opening from the top bar.
class _FlowPanel extends StatelessWidget {
  const _FlowPanel({
    required this.link,
    required this.tapGroupId,
    required this.flow,
    required this.onEnter,
    required this.onExit,
  });

  final LayerLink link;
  final Object tapGroupId;
  final _Flow flow;
  final VoidCallback onEnter;
  final VoidCallback onExit;

  /// Wide enough for the widest shape [OrchestrationNodeDiagram] draws — four
  /// pills and three connectors, 660px — plus the surface's own padding. The
  /// diagram scrolls sideways inside itself, so a window too narrow for this
  /// clamps below and loses nothing.
  static const double _width = 660 + 26;
  static const double _edgeMargin = 10;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final windowWidth = MediaQuery.sizeOf(context).width;
    return Positioned(
      width: math.min(_width, windowWidth - _edgeMargin * 2),
      child: CompositedTransformFollower(
        link: link,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 6),
        child: MouseRegion(
          onEnter: (_) => onEnter(),
          onExit: (_) => onExit(),
          child: TapRegion(
            groupId: tapGroupId,
            child: PillPanelSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PanelHeader(flow: flow),
                  if (flow.nodes case final diagram?) ...[
                    diagram,
                    const SizedBox(height: 4),
                    // Said out loud rather than left to the dots to imply:
                    // the usage log counts requests, so a lit dot cannot mean
                    // what a reader would take it to mean unaided.
                    PillPanelMessage(text: _footnote(flow)),
                  ] else
                    PillPanelMessage(text: _emptyLine(flow.group)),
                ],
              ),
            ),
          ),
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

/// The panel's own first line: the mode, whether its models repeat, and the
/// same status the strip carries.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.flow});

  final _Flow flow;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Text(
            flow.group.mode.displayName,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          PillPanelBadge(label: flow.group.isFixed ? 'Fixed' : 'Dynamic'),
          const SizedBox(width: 10),
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
      ),
    );
  }
}
