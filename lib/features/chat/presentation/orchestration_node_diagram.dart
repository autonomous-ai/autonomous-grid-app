import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/code_text_scope.dart';

/// How far along a node's turn has gotten. 'You' and 'Answer' never carry
/// one — they are the request and the reply, not a step that runs.
enum NodeStatus { queued, running, done, rejected }

/// One box in an [OrchestrationNodeDiagram] — a model id, or the literal
/// `'You'`/`'Answer'` for the two ends every diagram frames itself with.
/// Never a role name ("Proposer"/"Worker"/"Judge") — the diagram says what a
/// node *is* (a model), the layout it sits in says what it's *for*.
class DiagramNode {
  const DiagramNode(this.label, this.status);

  final String label;
  final NodeStatus status;
}

/// Fixed geometry every layout in this file shares, so a node reads as the
/// same box wherever it appears and a connector always meets one at the same
/// point.
const double _kNodeWidth = 200;
const double _kNodeHeight = 50;
const double _kNodeGap = 12; // between stacked proposer pills
const double _kConnectorWidth = 44;
const double _kLoopArcHeight = 26;
const double _kLoopArcGap = 6; // air between the pills and the arc's foot
const double _kLoopLabelHeight = 16;

/// The tallest a Brute Force diagram gets, stacking [maxProposers] proposer
/// nodes — what a container framing the diagram should reserve so picking
/// fewer models never visibly shrinks the card around it.
double bruteForceDiagramHeight(int maxProposers) =>
    maxProposers <= 0
        ? _kNodeHeight
        : maxProposers * _kNodeHeight + (maxProposers - 1) * _kNodeGap;

/// The Judge Loop diagram's height — fixed, since its shape never varies
/// with what's pinned.
const double judgeLoopDiagramHeight =
    _kNodeHeight + _kLoopArcGap + _kLoopArcHeight + _kLoopLabelHeight;

/// A horizontal node-and-connector diagram: **You → models → Answer**.
///
/// Pure and stateless — every node's data (label, status) comes in through
/// the constructor, and nothing here reaches for a provider or the network.
/// That's what lets the same widget serve two callers: the routing setup
/// dialog renders it once with every node fixed at [NodeStatus.queued] (a
/// preview of what a turn *would* look like), and the live workflow view
/// renders it again, driven by a real turn's per-node status as it runs.
///
/// Two named constructors rather than one generic graph renderer — Brute
/// Force's fan-out/fan-in and Feedback Loop's forward-plus-loop-back pair are
/// structurally different shapes, not variations on one layout.
class OrchestrationNodeDiagram extends StatelessWidget {
  const OrchestrationNodeDiagram._(this._body);

  final Widget _body;

  /// You fans out into [proposers], which fan back into [aggregator], then
  /// flow to [answer]. [proposers] should hold at least one node; an empty
  /// list draws a bare You→Aggregator→Answer line.
  ///
  /// [showStatus] hides each node's status dot — the setup dialog's preview
  /// fixes every node at [NodeStatus.queued] (nothing is actually running
  /// yet), so a dot that can never read as anything else is a mark with
  /// nothing to say. The live workflow view leaves it on the default.
  factory OrchestrationNodeDiagram.bruteForce({
    required DiagramNode you,
    required List<DiagramNode> proposers,
    required DiagramNode aggregator,
    required DiagramNode answer,
    bool showStatus = true,
  }) => OrchestrationNodeDiagram._(
    _BruteForceFlow(
      you: you,
      proposers: proposers,
      aggregator: aggregator,
      answer: answer,
      showStatus: showStatus,
    ),
  );

  /// You flows to [worker], which trades drafts with [judge] over a forward
  /// line and a curved [loopLabel] line looping back — then flows to
  /// [answer]. One arc stands for every round; the diagram never repeats the
  /// pair per round.
  ///
  /// See [bruteForce] for [showStatus].
  factory OrchestrationNodeDiagram.judgeLoop({
    required DiagramNode you,
    required DiagramNode worker,
    required DiagramNode judge,
    required DiagramNode answer,
    String loopLabel = 'revise',
    bool showStatus = true,
  }) => OrchestrationNodeDiagram._(
    _JudgeLoopFlow(
      you: you,
      worker: worker,
      judge: judge,
      answer: answer,
      loopLabel: loopLabel,
      showStatus: showStatus,
    ),
  );

  @override
  Widget build(BuildContext context) {
    // A diagram, not prose with a model id in it — CodeTextScope is for
    // exactly this ("a diff, a log pane, a code block, a terminal-style
    // readout"). Every node/connector here is a fixed pixel box, so growing
    // node labels with the UI's text scale would overflow the pills instead
    // of the diagram simply growing with them.
    return CodeTextScope(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _body,
      ),
    );
  }
}

/// You → (fan-out) → stacked proposers → (fan-in) → aggregator → Answer.
class _BruteForceFlow extends StatelessWidget {
  const _BruteForceFlow({
    required this.you,
    required this.proposers,
    required this.aggregator,
    required this.answer,
    required this.showStatus,
  });

  final DiagramNode you;
  final List<DiagramNode> proposers;
  final DiagramNode aggregator;
  final DiagramNode answer;
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final count = proposers.length;
    // The column's own natural height — no slack, so a proposer's index
    // alone gives its centre, and that centre lines up with the row's centre
    // (the row is exactly this tall, see the SizedBox below).
    final totalHeight = count == 0
        ? _kNodeHeight
        : count * _kNodeHeight + (count - 1) * _kNodeGap;
    final centers = [
      for (var i = 0; i < count; i++)
        i * (_kNodeHeight + _kNodeGap) + _kNodeHeight / 2,
    ];

    return SizedBox(
      height: totalHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _NodePill(you, showStatus: showStatus),
          _DashedConnector(
            size: Size(_kConnectorWidth, totalHeight),
            buildPath: (size) => centers.length <= 1
                ? _straightPath(size)
                : _fanOutPath(size, centers),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < count; i++) ...[
                if (i > 0) const SizedBox(height: _kNodeGap),
                _NodePill(proposers[i], showStatus: showStatus),
              ],
            ],
          ),
          _DashedConnector(
            size: Size(_kConnectorWidth, totalHeight),
            buildPath: (size) => centers.length <= 1
                ? _straightPath(size)
                : _fanInPath(size, centers),
          ),
          _NodePill(aggregator, showStatus: showStatus),
          _DashedConnector(
            size: Size(_kConnectorWidth, totalHeight),
            buildPath: _straightPath,
          ),
          _NodePill(answer, showStatus: showStatus),
        ],
      ),
    );
  }
}

/// You → worker/judge pair (forward line + curved loop-back) → Answer.
class _JudgeLoopFlow extends StatelessWidget {
  const _JudgeLoopFlow({
    required this.you,
    required this.worker,
    required this.judge,
    required this.answer,
    required this.loopLabel,
    required this.showStatus,
  });

  final DiagramNode you;
  final DiagramNode worker;
  final DiagramNode judge;
  final DiagramNode answer;
  final String loopLabel;
  final bool showStatus;

  // The arc spans worker's centre to judge's centre: half a node past the
  // row's start, one node plus one connector wide.
  static const double _arcLeft = _kNodeWidth * 1.5 + _kConnectorWidth;
  static const double _arcWidth = _kNodeWidth + _kConnectorWidth;
  static const double _rowWidth = _kNodeWidth * 4 + _kConnectorWidth * 3;
  static const double _totalHeight =
      _kNodeHeight + _kLoopArcGap + _kLoopArcHeight + _kLoopLabelHeight;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      height: _totalHeight,
      width: _rowWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            bottom: 0,
            left: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _NodePill(you, showStatus: showStatus),
                _DashedConnector(
                  size: const Size(_kConnectorWidth, _kNodeHeight),
                  buildPath: _straightPath,
                ),
                _NodePill(worker, showStatus: showStatus),
                _DashedConnector(
                  size: const Size(_kConnectorWidth, _kNodeHeight),
                  buildPath: _straightPath,
                ),
                _NodePill(judge, showStatus: showStatus),
                _DashedConnector(
                  size: const Size(_kConnectorWidth, _kNodeHeight),
                  buildPath: _straightPath,
                ),
                _NodePill(answer, showStatus: showStatus),
              ],
            ),
          ),
          Positioned(
            left: _arcLeft,
            bottom: _kNodeHeight + _kLoopArcGap,
            width: _arcWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  loopLabel,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: AppFont.medium,
                    color: AppPalette.textFaint,
                  ),
                ),
                const SizedBox(height: 2),
                _DashedConnector(
                  size: const Size(_arcWidth, _kLoopArcHeight),
                  // Judge → worker: the arc runs the direction the loop
                  // actually does (a rejected draft goes back for revision),
                  // which is right-to-left here since judge sits right of
                  // worker in reading order.
                  buildPath: _loopBackPath,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A model-name pill: mono text (model ids are copied, not read) — except for
/// 'You'/'Answer', which are the ends of the flow, not a step in it. A coloured
/// border, not an inline dot, marks the pill the grid is answering with right
/// now: a running node glows so the active step stands out at a glance.
class _NodePill extends StatelessWidget {
  const _NodePill(this.node, {this.showStatus = true});

  final DiagramNode node;
  final bool showStatus;

  bool get _isEndpoint => node.label == 'You' || node.label == 'Answer';

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      width: _kNodeWidth,
      height: _kNodeHeight,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: _isEndpoint ? AppGlass.bubbleFill : AppPalette.cardBg,
          borderRadius: BorderRadius.circular(AppControl.radius),
          border: Border.all(
            // Activity is a border glow, not a dot: the step being answered
            // right now draws a coloured edge so it reads at a glance.
            color: (!_isEndpoint && showStatus &&
                    node.status == NodeStatus.running)
                ? AppPalette.online
                : AppPalette.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                node.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppFont.codeStyle(
                  color: AppPalette.textPrimary,
                  scale: 1.12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// REMOVED: the inline status dot lived here. Activity now shows as a coloured
/// border on [_NodePill] (online = running) instead. Kept [NodeStatus] and the
/// enum keys' colours only where a node outside a pill still needs them.

/// A straight line across [size], left edge to right edge.
Path _straightPath(Size size) => Path()
  ..moveTo(0, size.height / 2)
  ..lineTo(size.width, size.height / 2);

/// A single left-edge point fanning out into [targets] on the right — the
/// You→proposers spread. One sub-path per target, each its own contour, so
/// the dash pattern in [_DashPainter] walks and animates every branch alike.
///
/// A cubic S-curve, not a quadratic — a quadratic's one control point pulls
/// the whole bend toward whichever endpoint it shares a height with, so the
/// path rides flat off the start then bends sharply into the target. Two
/// control points, one held at the start's height and one at the end's, bow
/// smoothly away from the straight line for the full width instead.
Path _fanOutPath(Size size, List<double> targets) {
  final path = Path();
  final startY = size.height / 2;
  final midX = size.width / 2;
  for (final endY in targets) {
    path
      ..moveTo(0, startY)
      ..cubicTo(midX, startY, midX, endY, size.width, endY);
  }
  return path;
}

/// [sources] on the left converging into a single right-edge point — the
/// proposers→aggregator merge, the mirror of [_fanOutPath]. See it for why
/// this is a cubic S-curve rather than a quadratic bend.
Path _fanInPath(Size size, List<double> sources) {
  final path = Path();
  final endY = size.height / 2;
  final midX = size.width / 2;
  for (final startY in sources) {
    path
      ..moveTo(0, startY)
      ..cubicTo(midX, startY, midX, endY, size.width, endY);
  }
  return path;
}

/// The "revise" arc above the worker/judge pair: starts at the bottom-right
/// (judge's side) and ends at the bottom-left (worker's side), climbing over
/// the top — so the flow direction (judge → worker) matches what the loop
/// actually does.
Path _loopBackPath(Size size) => Path()
  ..moveTo(size.width, size.height)
  ..cubicTo(size.width, 0, 0, 0, 0, size.height);

/// One flowing dashed connector — the single visual style every line in this
/// diagram uses, whatever shape [buildPath] describes. Built as a
/// [CustomPainter] over a [Path] the geometry functions above construct, not
/// hand-authored SVG.
class _DashedConnector extends StatefulWidget {
  const _DashedConnector({required this.size, required this.buildPath});

  final Size size;
  final Path Function(Size size) buildPath;

  @override
  State<_DashedConnector> createState() => _DashedConnectorState();
}

class _DashedConnectorState extends State<_DashedConnector>
    with SingleTickerProviderStateMixin {
  // One dash+gap period (see `_DashPainter._period`) per cycle, so the wrap
  // is seamless — but slow enough that the crawl reads as a continuous flow
  // rather than a fast, noticeable repeat over these short connectors.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce Motion: hold the dash pattern still instead of looping it — the
    // same rule `StatusDot`'s pulse halo follows.
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final color = AppPalette.textFaint;
    return RepaintBoundary(
      child: SizedBox.fromSize(
        size: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _DashPainter(
              path: widget.buildPath(widget.size),
              phase: _controller.value,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  _DashPainter({required this.path, required this.phase, required this.color});

  final Path path;

  /// 0..1 through one loop — [_dashed] turns it into a distance along the
  /// path so the pattern appears to travel from each contour's start toward
  /// its end (see that method).
  final double phase;
  final Color color;

  static const double _dashLength = 5;
  static const double _dashGap = 4;
  static const double _period = _dashLength + _dashGap;
  static const double _strokeWidth = 1.6;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(_dashed(path, phase * _period), paint);
  }

  /// Walks every contour of [source] and keeps only the segments the dash
  /// pattern covers, offset by [offset]. Increasing [offset] slides each
  /// dash from distance 0 toward higher distance — i.e. from the contour's
  /// start toward its end, which every geometry function above always builds
  /// as upstream-node → downstream-node. That's what makes "the dashes flow
  /// toward the next node" true for every connector in the diagram at once,
  /// without each shape having to reason about screen direction separately.
  ///
  /// Starts one whole period *before* distance 0, not at `offset % _period`
  /// itself — a plain `offset % _period` start leaves everything before it
  /// undrawn, so the gap at the contour's very start (right where it meets
  /// the upstream node) grows from nothing up to a full period as the phase
  /// climbs, then snaps shut the instant the phase wraps. Sat right next to
  /// the node the eye is already on, that snap reads as the flow lurching
  /// backward rather than a smooth, endless crawl. Starting a period early
  /// and clamping into range instead draws that same stretch as a dash
  /// shrinking smoothly to nothing — never an empty gap that closes with a
  /// jump.
  static Path _dashed(Path source, double offset) {
    final result = Path();
    for (final metric in source.computeMetrics()) {
      var distance = (offset % _period) - _period;
      while (distance < metric.length) {
        final start = distance.clamp(0.0, metric.length);
        final end = (distance + _dashLength).clamp(0.0, metric.length);
        if (end > start) {
          result.addPath(metric.extractPath(start, end), Offset.zero);
        }
        distance += _period;
      }
    }
    return result;
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => true;
}
