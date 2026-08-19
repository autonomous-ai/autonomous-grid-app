import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/docx_format.dart';
import '../../logic/docx_paragraph_style.dart';
import '../../logic/office_doc_controller.dart';
import '../../logic/office_doc_state.dart';
import '../../logic/office_page_metrics.dart';

/// How thick a ruler is drawn. Enough for a number and its tick, and no more —
/// the page is the thing on this screen.
const _rulerBreadth = 22.0;

/// One inch on screen. The ruler counts inches because the document does: a
/// `.docx` measures in twips, which is 1440ths of one.
const _inchPx = 96.0;

/// The tick between whole inches, and the one between those.
const _halfPx = _inchPx / 2;
const _eighthPx = _inchPx / 8;

/// The ruler above the page — where the margins are, and where the paragraph
/// under the caret starts and stops.
///
/// It is not decoration: the three markers are the paragraph's own indents and
/// they are **draggable**, which is the way Word and Google Docs have always let
/// somebody set an indent without knowing the word "indent". Dragging one writes
/// the same `w:ind` the toolbar's indent buttons write — see
/// [DocxParagraphStyle].
///
/// Drawn against [OfficePageMetrics] so its zero is the page's own left margin,
/// to the pixel, at every window width.
class OfficeHorizontalRuler extends ConsumerWidget {
  const OfficeHorizontalRuler({super.key, required this.doc});

  final OfficeDocOpen doc;

  static const height = _rulerBreadth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final format = doc.formatAt(doc.caretLine);
    return SizedBox(
      height: height,
      // The band runs the full width even though the scale only spans the
      // page: it carries on the light strip the toolbar starts, instead of
      // leaving a grey island floating over a dark desk.
      child: ColoredBox(
        color: AppPalette.paperChrome,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final metrics = OfficePageMetrics.of(
              constraints.maxWidth,
              doc.pageWidthPx,
            );
            // The sheet is centred in the pane, so everything drawn here is
            // offset by whatever is left over either side.
            final left = (constraints.maxWidth - metrics.page) / 2;
            return Stack(
              children: [
                Positioned(
                  left: left,
                  width: metrics.page,
                  top: 0,
                  bottom: 0,
                  child: CustomPaint(
                    painter: _RulerPainter(
                      inset: metrics.inset,
                      trailingInset: metrics.inset,
                      length: metrics.page,
                      horizontal: true,
                    ),
                  ),
                ),
                // Text starts at the margin plus the paragraph's own left
                // indent; its first line may sit further in, or hang out left.
                _Marker(
                  kind: _MarkerKind.firstLine,
                  x:
                      left +
                      metrics.inset +
                      format.indentLeftPx +
                      format.firstLinePx,
                  onMoved: (dx) => _nudgeFirstLine(ref, format, dx),
                ),
                _Marker(
                  kind: _MarkerKind.left,
                  x: left + metrics.inset + format.indentLeftPx,
                  onMoved: (dx) => _nudgeLeft(ref, format, dx),
                ),
                _Marker(
                  kind: _MarkerKind.right,
                  x: left + metrics.page - metrics.inset - format.indentRightPx,
                  onMoved: (dx) => _nudgeRight(ref, format, dx),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The three drags all end the same way: a pixel delta becomes twips, is
  /// stopped from going negative, and goes back as the one property it moved.
  void _apply(WidgetRef ref, DocxParagraphStyle change) =>
      ref.read(officeDocProvider.notifier).applyStyle(change);

  void _nudgeLeft(WidgetRef ref, DocxLineFormat format, double dx) {
    final at = docxTwipsOfPx(format.indentLeftPx + dx);
    _apply(ref, DocxParagraphStyle(indentLeftTwips: at < 0 ? 0 : at));
  }

  void _nudgeRight(WidgetRef ref, DocxLineFormat format, double dx) {
    // Right indent grows *leftwards*, so the drag's sign flips: pulling the
    // marker towards the middle of the page is a bigger indent.
    final at = docxTwipsOfPx(format.indentRightPx - dx);
    _apply(ref, DocxParagraphStyle(indentRightTwips: at < 0 ? 0 : at));
  }

  void _nudgeFirstLine(WidgetRef ref, DocxLineFormat format, double dx) =>
      _apply(
        ref,
        DocxParagraphStyle(
          firstLineTwips: docxTwipsOfPx(format.firstLinePx + dx),
        ),
      );
}

/// The ruler down the left of the page.
///
/// It measures rather than sets: the top and bottom margins it would otherwise
/// let somebody drag live in the section's `w:sectPr`, not in any paragraph, and
/// this editor writes paragraphs. Offering a handle that did nothing would be
/// worse than offering none (§5), so it draws the scale and stops there.
class OfficeVerticalRuler extends StatelessWidget {
  const OfficeVerticalRuler({super.key});

  static const width = _rulerBreadth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: LayoutBuilder(
        builder: (context, constraints) => CustomPaint(
          painter: _RulerPainter(
            // The air this editor actually leaves above the first paragraph —
            // not the document's own top margin, which lives in `w:sectPr` and
            // nothing here honours. A ruler must measure the page in front of
            // the user.
            inset: officePageTopInset,
            // No band at the bottom. The page's own end is somewhere down the
            // scroll, not at the bottom of the viewport, so a margin drawn
            // there would be measuring the window rather than the document.
            trailingInset: 0,
            length: constraints.maxHeight,
            horizontal: false,
          ),
        ),
      ),
    );
  }
}

/// The scale itself: the writing column marked as a band, ticks every eighth of
/// an inch and a number on every whole one.
///
/// **Light in both themes**, like the bar above it — see
/// [AppPalette.paperChrome] for why the furniture around a page does not follow
/// the app. It takes no colours from its caller for the same reason the page
/// takes none: there is nothing here to choose.
///
/// Three shades, which is what a ruler has: the strip, the page's margins
/// darker inside it, and the writing column lighter still. The marked part is
/// the part you may write in — marking the margins instead is what made this
/// read as a white strip starting an inch down.
class _RulerPainter extends CustomPainter {
  const _RulerPainter({
    required this.inset,
    required this.trailingInset,
    required this.length,
    required this.horizontal,
  });

  /// Where the writing column starts, and how much is margin at the far end.
  final double inset;
  final double trailingInset;

  final double length;
  final bool horizontal;

  /// One ink for the marks and the numbers alike, the way an engraved ruler has
  /// one. The hierarchy is tick *length*, not colour.
  static const _ink = AppPalette.paperChromeInk;

  @override
  void paint(Canvas canvas, Size size) {
    final band = horizontal ? size.height : size.width;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppPalette.paperChromeLine,
    );
    _band(canvas, size, inset, length - trailingInset, AppPalette.paper);

    final ticks = Paint()
      ..color = _ink
      ..strokeWidth = 1;
    // Measured from the text's own zero — the left (or top) margin — because
    // that is where a document's first inch starts, and it is the number a
    // person reading the ruler is looking for.
    for (var at = inset; at <= length - 1; at += _eighthPx) {
      _tickAt(canvas, band, at, ticks, _tickLengthFor(at - inset));
    }
    for (var at = inset - _eighthPx; at >= 0; at -= _eighthPx) {
      _tickAt(canvas, band, at, ticks, _tickLengthFor(inset - at));
    }
    _numbers(canvas, band);
    // The hairline the page hangs from, so the ruler and the bar above it read
    // as one strip.
    canvas.drawLine(
      horizontal ? Offset(0, size.height - 0.5) : Offset(size.width - 0.5, 0),
      horizontal
          ? Offset(size.width, size.height - 0.5)
          : Offset(size.width - 0.5, size.height),
      Paint()
        ..color = AppPalette.paperChromeLine
        ..strokeWidth = 1,
    );
  }

  /// A whole inch gets the long tick, a half the middle one, an eighth the
  /// shortest — the pattern every ruler uses, so it needs no explaining.
  double _tickLengthFor(double fromZero) {
    final into = fromZero % _inchPx;
    if (into < 0.5 || (_inchPx - into) < 0.5) return 0;
    if ((into - _halfPx).abs() < 0.5) return 5;
    return 3;
  }

  void _tickAt(Canvas canvas, double band, double at, Paint paint, double len) {
    if (len == 0) return;
    final mid = band / 2;
    canvas.drawLine(
      horizontal ? Offset(at, mid - len / 2) : Offset(mid - len / 2, at),
      horizontal ? Offset(at, mid + len / 2) : Offset(mid + len / 2, at),
      paint,
    );
  }

  /// Whole inches, counted outwards from the text's zero in both directions —
  /// so the margin reads 1 rather than 0, exactly as Word's does.
  void _numbers(Canvas canvas, double band) {
    for (var n = 1; n * _inchPx + inset < length; n++) {
      _label(canvas, band, inset + n * _inchPx, '$n');
    }
    for (var n = 1; inset - n * _inchPx > 0; n++) {
      _label(canvas, band, inset - n * _inchPx, '$n');
    }
  }

  void _label(Canvas canvas, double band, double at, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        // 9, not the 8.5 this started at: these are numbers read at a glance
        // out of the corner of the eye, and half a point is the difference
        // between a digit and a smudge.
        style: const TextStyle(color: _ink, fontSize: 9, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // No backing box behind the number. It used to paint one in the ruler's own
    // fill to punch a hole in the tick row — which needs the fill to be opaque,
    // and this one is a translucent overlay. The ticks already skip the whole
    // inch where a number goes ([_tickLengthFor] returns 0 there), so there is
    // nothing to hide.
    painter.paint(
      canvas,
      horizontal
          ? Offset(at - painter.width / 2, band / 2 - painter.height / 2)
          : Offset(band / 2 - painter.width / 2, at - painter.height / 2),
    );
  }

  void _band(Canvas canvas, Size size, double from, double to, Color color) =>
      canvas.drawRect(
        horizontal
            ? Rect.fromLTRB(from, 0, to, size.height)
            : Rect.fromLTRB(0, from, size.width, to),
        Paint()..color = color,
      );

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.inset != inset ||
      old.trailingInset != trailingInset ||
      old.length != length;
}

/// Which of the three indents a marker moves — and so which shape it wears.
enum _MarkerKind { firstLine, left, right }

/// One draggable indent marker.
///
/// The hit area is deliberately wider than the shape drawn in it: a 7px triangle
/// is something to aim at rather than something to grab, and the first-line and
/// left markers sit on top of each other whenever a paragraph has no first-line
/// indent at all.
class _Marker extends StatelessWidget {
  const _Marker({required this.kind, required this.x, required this.onMoved});

  final _MarkerKind kind;
  final double x;

  /// How far the pointer moved since the last report, in logical pixels.
  final ValueChanged<double> onMoved;

  static const _grab = 16.0;

  @override
  Widget build(BuildContext context) => Positioned(
    left: x - _grab / 2,
    top: 0,
    bottom: 0,
    width: _grab,
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onMoved(d.delta.dx),
        child: Tooltip(
          message: switch (kind) {
            _MarkerKind.firstLine => 'First line indent',
            _MarkerKind.left => 'Left indent',
            _MarkerKind.right => 'Right indent',
          },
          child: CustomPaint(
            painter: _MarkerPainter(kind: kind, color: AppPalette.accent),
          ),
        ),
      ),
    ),
  );
}

class _MarkerPainter extends CustomPainter {
  const _MarkerPainter({required this.kind, required this.color});

  final _MarkerKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final mid = size.width / 2;
    const half = 4.5;
    // The first-line marker points down from the top edge; the two that set the
    // body's own edges point up from the bottom. Word's shapes, and the only
    // thing that tells two markers apart when they sit at the same place.
    final down = kind == _MarkerKind.firstLine;
    final base = down ? 0.0 : size.height;
    final tip = down ? half * 1.6 : size.height - half * 1.6;
    canvas.drawPath(
      Path()
        ..moveTo(mid - half, base)
        ..lineTo(mid + half, base)
        ..lineTo(mid, tip)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_MarkerPainter old) =>
      old.kind != kind || old.color != color;
}
