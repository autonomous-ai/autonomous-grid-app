part of 'office_toolbar.dart';

/// The typefaces the picker offers.
///
/// The faces Word's own documents are written in, and the ones a desktop is
/// likely to actually have installed — a name Flutter cannot resolve falls back
/// to the system face, so offering a long list would be offering choices that
/// quietly do nothing. The paragraph's own font is added to this when it isn't
/// among them, so a document never fails to name what it is set in.
const _fonts = [
  'Arial',
  'Calibri',
  'Cambria',
  'Courier New',
  'Georgia',
  'Helvetica',
  'Times New Roman',
  'Verdana',
];

/// Word's default when a document names no face at all.
const _defaultFont = 'Calibri';

/// A plain press on this bar — the size steppers and the two indent buttons.
///
/// [AppIconButton] with the light chrome's inks handed to it, in one place, so
/// four call sites can't each pick their own shade of "on paper".
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: icon,
    size: 16,
    tooltip: tooltip,
    color: AppPalette.paperChromeInkSoft,
    hoverColor: AppPalette.paperChromeInk,
    hoverFill: AppPalette.paperChromeFill,
    onPressed: onPressed,
  );
}

/// A toolbar control that is either on or off — bold, and the alignment that is
/// currently in force.
///
/// Pressed state is a fill rather than only a brighter glyph: half the controls
/// on this bar are toggles and half are actions, and at a glance the fill is
/// what tells them apart.
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 1),
    decoration: BoxDecoration(
      color: active ? AppPalette.paperChromeFill : Colors.transparent,
      borderRadius: BorderRadius.circular(AppControl.radius),
    ),
    child: AppIconButton(
      icon: icon,
      size: 16,
      tooltip: tooltip,
      color: active ? AppPalette.paperChromeInk : AppPalette.paperChromeInkSoft,
      hoverColor: AppPalette.paperChromeInk,
      hoverFill: AppPalette.paperChromeFill,
      onPressed: onPressed,
    ),
  );
}

/// A menu that reports its current choice — the font picker and the line
/// spacing both.
class _MenuTrigger<T> extends StatelessWidget {
  const _MenuTrigger({
    required this.label,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    this.width,
    this.leading,
  });

  final String label;
  final String tooltip;
  final List<({T value, String label})> items;
  final ValueChanged<T> onSelected;
  final double? width;
  final IconData? leading;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: PopupMenuButton<T>(
      tooltip: '',
      // White, not the app's menu fill: this menu drops out of light chrome,
      // and a charcoal sheet under a light bar reads as a different app.
      color: AppPalette.paper,
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final item in items)
          PopupMenuItem(
            value: item.value,
            height: 34,
            child: Text(
              item.label,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppPalette.paperChromeInk,
              ),
            ),
          ),
      ],
      child: Container(
        width: width,
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              Icon(leading, size: 15, color: AppPalette.paperChromeInkSoft),
              const SizedBox(width: 5),
            ],
            if (width != null)
              Expanded(child: _label(context))
            else
              _label(context),
            const Icon(
              LucideIcons.chevronDown300,
              size: 13,
              color: AppPalette.paperChromeInkSoft,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _label(BuildContext context) => Text(
    label,
    overflow: TextOverflow.ellipsis,
    softWrap: false,
    style: const TextStyle(fontSize: 12.5, color: AppPalette.paperChromeInk),
  );
}

/// Which typeface the paragraph is set in.
class _FontPicker extends StatelessWidget {
  const _FontPicker({required this.format, required this.apply});

  final DocxLineFormat format;
  final _Apply apply;

  @override
  Widget build(BuildContext context) {
    final current = format.fontFamily ?? _defaultFont;
    final names = {..._fonts, current}.toList()..sort();
    return _MenuTrigger<String>(
      label: current,
      tooltip: 'Font',
      width: 128,
      items: [for (final name in names) (value: name, label: name)],
      onSelected: (name) => apply(DocxParagraphStyle(fontFamily: name)),
    );
  }
}

/// The type size, and the two buttons that step it.
///
/// The buttons walk [docxFontSizes] rather than adding a point, so 11 → 12 → 14
/// is two presses and not three — the sizes people actually set type at.
class _FontSize extends StatelessWidget {
  const _FontSize({required this.format, required this.apply});

  final DocxLineFormat format;
  final _Apply apply;

  double get _points => docxPointsOfHalfPoints(format.fontSizePx * 1.5);

  void _step(int direction) {
    final now = _points;
    final sizes = direction < 0
        ? docxFontSizes.reversed.toList()
        : docxFontSizes;
    for (final size in sizes) {
      final past = direction < 0 ? size < now - 0.01 : size > now + 0.01;
      if (past) {
        apply(DocxParagraphStyle(fontHalfPoints: docxHalfPointsOfPoints(size)));
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = _points;
    return Row(
      children: [
        _BarButton(
          icon: LucideIcons.minus300,
          tooltip: 'Smaller',
          onPressed: () => _step(-1),
        ),
        _MenuTrigger<double>(
          // A whole number where the size is one — "11", not "11.0", which is
          // how every other word processor writes it.
          label: now == now.roundToDouble()
              ? '${now.round()}'
              : now.toStringAsFixed(1),
          tooltip: 'Font size',
          width: 52,
          items: [
            for (final size in docxFontSizes)
              (value: size, label: '${size.round()}'),
          ],
          onSelected: (size) => apply(
            DocxParagraphStyle(fontHalfPoints: docxHalfPointsOfPoints(size)),
          ),
        ),
        _BarButton(
          icon: LucideIcons.plus300,
          tooltip: 'Bigger',
          onPressed: () => _step(1),
        ),
      ],
    );
  }
}

/// Bold, italic, underline.
class _Weight extends StatelessWidget {
  const _Weight({required this.format, required this.apply});

  final DocxLineFormat format;
  final _Apply apply;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _Toggle(
        icon: LucideIcons.bold,
        tooltip: 'Bold',
        active: format.bold,
        onPressed: () => apply(DocxParagraphStyle(bold: !format.bold)),
      ),
      _Toggle(
        icon: LucideIcons.italic,
        tooltip: 'Italic',
        active: format.italic,
        onPressed: () => apply(DocxParagraphStyle(italic: !format.italic)),
      ),
      _Toggle(
        icon: LucideIcons.underline,
        tooltip: 'Underline',
        active: format.underline,
        onPressed: () =>
            apply(DocxParagraphStyle(underline: !format.underline)),
      ),
    ],
  );
}

/// How the paragraph's lines sit against the column.
class _Align extends StatelessWidget {
  const _Align({required this.format, required this.apply});

  final DocxLineFormat format;
  final _Apply apply;

  static const _choices = [
    (DocxTextAlign.left, LucideIcons.alignLeft, 'Align left'),
    (DocxTextAlign.center, LucideIcons.alignCenter, 'Centre'),
    (DocxTextAlign.right, LucideIcons.alignRight, 'Align right'),
    (DocxTextAlign.justify, LucideIcons.alignJustify, 'Justify'),
  ];

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final (align, icon, label) in _choices)
        _Toggle(
          icon: icon,
          tooltip: label,
          active: format.align == align,
          onPressed: () => apply(DocxParagraphStyle(align: align)),
        ),
    ],
  );
}

/// The gap between the paragraph's own lines.
class _LineSpacing extends StatelessWidget {
  const _LineSpacing({required this.format, required this.apply});

  final DocxLineFormat format;
  final _Apply apply;

  @override
  Widget build(BuildContext context) => _MenuTrigger<double>(
    // `lineHeight` is the multiple times the 1.2 `docx_format.dart` uses for
    // single spacing, so it comes back out the same way.
    label: (format.lineHeight / 1.2).toStringAsFixed(2),
    tooltip: 'Line spacing',
    leading: LucideIcons.chevronsUpDown300,
    items: [
      for (final spacing in docxLineSpacings)
        (value: spacing, label: spacing.toStringAsFixed(2)),
    ],
    onSelected: (spacing) => apply(DocxParagraphStyle(lineSpacing: spacing)),
  );
}

/// Moving the whole paragraph in from the margin, and back out again.
class _Indent extends StatelessWidget {
  const _Indent({required this.format, required this.apply});

  final DocxLineFormat format;
  final _Apply apply;

  void _move(int direction) {
    final now = docxTwipsOfPx(format.indentLeftPx);
    final next = now + direction * docxIndentStepTwips;
    // Never past the margin: a negative left indent puts text outside the page
    // Word would print, and the button that got it there gives no clue how to
    // get back.
    apply(DocxParagraphStyle(indentLeftTwips: next < 0 ? 0 : next));
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _BarButton(
        icon: LucideIcons.indentDecrease300,
        tooltip: 'Decrease indent',
        onPressed: format.indentLeftPx <= 0 ? null : () => _move(-1),
      ),
      _BarButton(
        icon: LucideIcons.indentIncrease300,
        tooltip: 'Increase indent',
        onPressed: () => _move(1),
      ),
    ],
  );
}
