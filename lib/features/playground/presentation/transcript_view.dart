import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../shared/theme/app_theme.dart';
import 'chat_minimap.dart';

/// How close to the end (px) still counts as "at the bottom" — within this, new
/// turns auto-follow and the jump-to-latest button hides. Shared with the
/// caller, which tracks the same threshold to drive its own follow behaviour.
const double kAtBottomThreshold = 120;

/// How wide the conversation column gets on a big window. Long lines are hard to
/// read; every transcript in the app shares this so the two halves — Chat and
/// Code — line up at the same measure.
const double kTranscriptColumnWidth = 1000;

/// How much taller than the window the conversation has to be before the minimap
/// rail appears. A chat you can almost see all of doesn't need a table of
/// contents — the rail would just be clutter beside it.
const double _railMinContentRatio = 1.5;

/// One turn in a transcript, told apart from how it is drawn.
///
/// The scrolling shell is shared between Chat and Code, but a turn is a chat
/// bubble in one and a whole task — question, live steps, result — in the other.
/// So the shell takes a [builder] rather than a message, and two ids it needs to
/// do its job without knowing what the turn is:
///
///  - [scrollId] is stable for the life of the turn. It keys the turn's
///    `GlobalKey`, which the minimap scrolls to and measures "where am I" from,
///    so it must not change as the turn's contents do — a task's id, not its
///    state.
///  - [cacheId] changes when the drawn content changes. The shell holds the
///    built widget under it and hands the same instance back on every later
///    rebuild, so a keystroke in the composer doesn't re-derive markdown the
///    user is already looking at — but a task going from running to done must
///    fold its new state in, so its cache id carries that state.
class TranscriptRow {
  const TranscriptRow({
    required this.scrollId,
    required this.cacheId,
    required this.builder,
  });

  final Object scrollId;
  final Object cacheId;
  final WidgetBuilder builder;
}

/// The scrolling conversation: the minimap rail down the left, the turns in a
/// centred column, and a "jump to latest" button while the user has scrolled up
/// into the history.
///
/// The one shell both halves of the app share. Home and Code differ in the rail
/// on the far left and the box underneath — not in how a conversation reads — so
/// this owns everything between: the lazy list, the centred column, the minimap,
/// the row cache and the jump button. The scroll controller stays with the
/// caller, which drives its own follow-and-snap behaviour (a streamed reply and
/// a polled task list land new turns very differently).
///
/// The ListView spans the *full* pane and each turn is centred within it, rather
/// than the list itself being boxed to [kTranscriptColumnWidth]. A scrollbar
/// hangs off its list's right edge — boxing the list put that edge in the middle
/// of the window, leaving the bar floating in open space instead of riding the
/// window edge.
class TranscriptView extends StatefulWidget {
  const TranscriptView({
    super.key,
    required this.scroll,
    required this.rows,
    required this.marksOf,
    required this.trailing,
    required this.atBottom,
    required this.onJumpToLatest,
    this.columnWidth = kTranscriptColumnWidth,
  });

  final ScrollController scroll;
  final List<TranscriptRow> rows;

  /// The rail's ticks, computed lazily — walking a whole transcript to clip a
  /// preview from each turn is real work, and this build runs on every keystroke
  /// in the composer. Called only when the turns actually change.
  final List<MinimapMark> Function() marksOf;

  /// The in-flight bubble drawn after the turns, or null. Not a [TranscriptRow]:
  /// it is what changes on every streamed token, which is the whole reason the
  /// turns above it are cached and it is not.
  final Widget? trailing;

  final bool atBottom;
  final VoidCallback onJumpToLatest;
  final double columnWidth;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  /// One key per turn, so the minimap can scroll a turn into view by its own
  /// rendered position — turns are wildly uneven in height (a one-line question
  /// against a long reply), so there's no arithmetic that maps an index to an
  /// offset. Keyed by [TranscriptRow.scrollId], which outlives the turn's
  /// changing contents.
  final _itemKeys = <Object, GlobalKey>{};

  /// The built widget for each turn, so a rebuild of the view above doesn't
  /// re-derive every visible turn. Keyed by [TranscriptRow.cacheId], which
  /// changes when the drawn content does.
  final _rows = <Object, Widget>{};

  /// The rail's ticks, derived once per transcript rather than per build. Null
  /// until the first build that needs it, and dropped when the turns change.
  List<MinimapMark>? _marks;

  /// The turn index the rail marks as "where you are", or null before the first
  /// frame has measured anything.
  int? _currentIndex;

  /// Whether the transcript is long enough to be worth a rail.
  bool _railVisible = false;

  GlobalKey _keyFor(Object scrollId) =>
      _itemKeys.putIfAbsent(scrollId, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_onScroll);
    // The list hasn't been laid out yet, so nothing is measurable until after
    // the first frame — resolve both the rail's visibility and the current turn
    // then.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void didUpdateWidget(TranscriptView old) {
    super.didUpdateWidget(old);
    if (old.scroll != widget.scroll) {
      old.scroll.removeListener(_onScroll);
      widget.scroll.addListener(_onScroll);
    }
    // Compared by turn identity, not list instance: the caller rebuilds the rows
    // list on every keystroke, and treating each new list as a change would drop
    // the row cache and recompute the rail on every one of them.
    if (!_sameRows(old.rows, widget.rows)) _onTranscriptChanged();
    if (old.rows.length != widget.rows.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  /// Whether two builds describe the same turns — same ids, in the same order.
  bool _sameRows(List<TranscriptRow> a, List<TranscriptRow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].cacheId != b[i].cacheId || a[i].scrollId != b[i].scrollId) {
        return false;
      }
    }
    return true;
  }

  /// Drop what was derived from the old transcript: the cached rows and keys of
  /// turns no longer in it, and the rail's ticks. Appending a turn keeps every
  /// earlier one, since their ids carry over.
  void _onTranscriptChanged() {
    final cacheIds = {for (final row in widget.rows) row.cacheId};
    final scrollIds = {for (final row in widget.rows) row.scrollId};
    _rows.removeWhere((id, _) => !cacheIds.contains(id));
    _itemKeys.removeWhere((id, _) => !scrollIds.contains(id));
    _marks = null;
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_onScroll);
    super.dispose();
  }

  /// Track what the rail should show: whether it's worth showing at all, and
  /// which turn the user is currently reading.
  void _onScroll() {
    if (!mounted || !widget.scroll.hasClients) return;
    final pos = widget.scroll.position;
    // The rail earns its place only on a transcript worth navigating: total
    // content at least [_railMinContentRatio] of the viewport. maxScrollExtent
    // is the *overflow*, so the content is that plus the viewport itself.
    final visible =
        pos.hasContentDimensions &&
        pos.maxScrollExtent + pos.viewportDimension >=
            pos.viewportDimension * _railMinContentRatio;
    // At the very bottom the reading line can't be reached by the last turns —
    // the list has run out of scroll, so a short final turn sits below it
    // forever and the mark would stall an item or two early. Scrolled to the end
    // *is* being at the last turn, so say so directly.
    final atEnd =
        pos.hasContentDimensions &&
        pos.pixels >= pos.maxScrollExtent - kAtBottomThreshold;
    // A null reading means nothing measurable has passed the line *this frame* —
    // mid-fling, say. Keep the last answer rather than dropping the mark back to
    // the top of the rail. Only worth measuring while the rail is up.
    final current = !visible
        ? _currentIndex
        : atEnd
        ? widget.rows.length - 1
        : (_currentTurn() ?? _currentIndex);
    if (visible != _railVisible || current != _currentIndex) {
      setState(() {
        _railVisible = visible;
        _currentIndex = current;
      });
    }
  }

  /// The turn the user is reading: the last one whose top has passed the
  /// viewport's reading line. Turns are far taller than the rail's ticks, so
  /// "which one is on screen" has to be measured from the laid-out items rather
  /// than interpolated from the scroll offset.
  ///
  /// Only *built* items can be measured: the list is lazy, so turns scrolled far
  /// off either end have no render object. That's why the answer is the highest
  /// match rather than the first miss — an unbuilt item above the viewport is
  /// above the line whether or not it can say so.
  int? _currentTurn() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final line = box.size.height * 0.2;
    int? found;
    for (var i = 0; i < widget.rows.length; i++) {
      final itemContext = _itemKeys[widget.rows[i].scrollId]?.currentContext;
      if (itemContext == null) continue;
      final item = itemContext.findRenderObject() as RenderBox?;
      if (item == null || !item.hasSize || !item.attached) continue;
      final top = item.localToGlobal(Offset.zero, ancestor: box).dy;
      if (top <= line) found = i;
    }
    return found;
  }

  /// The transcript row for [row] — built once and handed back unchanged on
  /// every later rebuild, so Flutter skips the whole subtree instead of
  /// re-deriving markdown the user is already looking at.
  Widget _turn(TranscriptRow row) => _rows[row.cacheId] ??= _TurnColumn(
    key: _keyFor(row.scrollId),
    maxWidth: widget.columnWidth,
    child: row.builder(context),
  );

  /// Bring turn [index] to the top of the viewport. Built turns scroll via their
  /// key; one recycled out of the lazy list has no context, so it falls back to
  /// an estimate from its position in the transcript.
  void _jumpTo(int index) {
    if (index < 0 || index >= widget.rows.length) return;
    final context = _itemKeys[widget.rows[index].scrollId]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        // Land the turn just below the pane's top edge rather than dead-centre:
        // a question is a heading for what follows, so what the user wants to
        // read is underneath it.
        alignment: 0.05,
      );
      return;
    }
    if (!widget.scroll.hasClients || widget.rows.length <= 1) return;
    final pos = widget.scroll.position;
    final t = index / (widget.rows.length - 1);
    widget.scroll.animateTo(
      (pos.maxScrollExtent * t).clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// Take any open tooltip down the moment the transcript starts moving.
  ///
  /// A tooltip has no idea the thing it points at is scrolling away — it stays
  /// pinned where it opened, over rows it no longer describes. And one left open
  /// across a scroll is how the app froze on 2026-08-06: Flutter hit-tests the
  /// tooltip's overlay before that overlay has been laid out, which throws inside
  /// the mouse tracker's own update and then re-throws on every frame after.
  ///
  /// Returns false — the notification is still the scrollbar's business too.
  bool _dismissTooltips(ScrollStartNotification _) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => Tooltip.dismissAllToolTips(),
      );
      return false;
    }
    Tooltip.dismissAllToolTips();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.rows.length + (widget.trailing != null ? 1 : 0);
    return Stack(
      children: [
        NotificationListener<ScrollStartNotification>(
          onNotification: _dismissTooltips,
          child: ListView.builder(
            controller: widget.scroll,
            // No horizontal padding: the list spans the pane so its scrollbar
            // sits on the window edge. The column below insets its own content.
            padding: const EdgeInsets.symmetric(vertical: 18),
            itemCount: count,
            itemBuilder: (context, i) => i < widget.rows.length
                ? _turn(widget.rows[i])
                // Not cached: the in-flight bubble is what changes on every
                // streamed token, which is the whole reason the turns above it
                // must not.
                : _TurnColumn(
                    maxWidth: widget.columnWidth,
                    child: widget.trailing ?? const SizedBox.shrink(),
                  ),
          ),
        ),
        if (_railVisible)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: ChatMinimap(
              marks: _marks ??= widget.marksOf(),
              currentIndex: _currentIndex,
              onJumpTo: _jumpTo,
            ),
          ),
        if (!widget.atBottom)
          Positioned(
            right: 20,
            bottom: 12,
            child: _JumpToLatestButton(onTap: widget.onJumpToLatest),
          ),
      ],
    );
  }
}

/// One row of the transcript: a turn (or the in-flight bubble) held to the
/// conversation column and optically centred in the pane.
///
/// The list spans the whole pane so its scrollbar rides the window edge, so the
/// measure has to be applied per row rather than by boxing the list.
class _TurnColumn extends StatelessWidget {
  const _TurnColumn({super.key, required this.child, required this.maxWidth});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Padding(
        // The rail's width on the left, mirrored on the right, so the column
        // stays optically centred instead of nudged off-axis.
        padding: const EdgeInsets.symmetric(horizontal: chatMinimapWidth),
        child: child,
      ),
    ),
  );
}

/// A round "jump to latest" button shown while the user has scrolled up. Tapping
/// animates back to the newest turn so they never have to drag to the bottom by
/// hand.
class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppGlass tokens — follow theme flips. Without this the
    // button keeps whichever theme's colours it was first built under.
    AppTheme.watch(context);
    return Tooltip(
      message: 'Jump to latest',
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: AppGlass.cardShadow,
        ),
        child: Material(
          color: AppGlass.surfaceFill,
          shape: CircleBorder(side: BorderSide(color: AppGlass.lift)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 24,
                color: AppPalette.textPrimary,
                semanticLabel: 'Jump to latest',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
