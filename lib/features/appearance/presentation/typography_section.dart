import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/platform/system_fonts.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/labeled_field.dart';
// SectionHeading lives with the grid overview widgets, but it is the app's one
// in-content heading (19/w700, per §6 of the design system) — not a token this
// screen should re-type at 13pt, which is what it did before.
import '../../network/presentation/grid_overview_widgets.dart';
// The chat's own code block, reused rather than imitated — see _TypePreview.
import '../../playground/presentation/markdown_builders.dart';

/// The type settings: which faces the app is set in, and at what size.
///
/// Built the way the reference tabs are (Plugins, Grids): a `SectionHeading`
/// over a stack of raised rows, each a `AppGlass.surfaceFill` surface with the
/// app's `cardShadow` at radius 14. That surface is not decoration — the design
/// system measures page-to-card contrast at **1.105:1** in dark and **1.054:1**
/// in light, so a block that changes only its fill is invisible and the shadow
/// is the thing that actually separates the layers. Four settings laid straight
/// onto the page, as this screen first had them, read as loose text rather than
/// as a group of controls.
///
/// Within a row: the name and a sentence of explanation on the left, the control
/// on the right — the macOS settings shape, where a row says "here is a thing,
/// here is its current value". A form of stacked labelled fields says "fill all
/// of this in", which is the wrong instruction for a preference that already has
/// a value.
class TypographySection extends ConsumerWidget {
  const TypographySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final prefs = ref.watch(chatPrefsProvider);
    // Missing until the platform answers, and simply absent under `flutter
    // test`. Either way the curated names still work — see buildFontOptions.
    final installed =
        ref.watch(installedFontFamiliesProvider).asData?.value ??
        InstalledFonts.none;
    final controller = ref.read(chatPrefsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          title: 'Typography',
          subtitle:
              'The faces the app is set in, and how big. '
              'Code is sized on its own, so it can stay compact in a larger UI.',
        ),
        const SizedBox(height: 14),
        _SettingRow(
          title: 'UI font',
          description: 'Every label, menu and heading in the app',
          control: _FontPicker(
            key: const Key('ui-font-picker'),
            label: 'UI font',
            curated: kCuratedUiFonts,
            installed: installed.all,
            value: prefs.uiFontFamily,
            onChanged: controller.setUiFontFamily,
          ),
        ),
        const SizedBox(height: 8),
        _SettingRow(
          title: 'UI font size',
          description: 'The base size everything else scales against',
          control: _SizeField(
            fieldKey: const Key('ui-font-size'),
            value: prefs.uiFontSize,
            min: ChatPrefs.minUiFontSize,
            max: ChatPrefs.maxUiFontSize,
            onChanged: controller.setUiFontSize,
          ),
        ),
        const SizedBox(height: 8),
        _SettingRow(
          title: 'Code font',
          description: 'Code blocks, diffs and command output',
          control: _FontPicker(
            key: const Key('code-font-picker'),
            label: 'Code font',
            curated: kCuratedCodeFonts,
            // Only the fixed-pitch families: offering the full list here is
            // what put Apple Symbols in the code picker, and a symbol face
            // renders source as pictograms.
            installed: installed.monospaced,
            value: prefs.codeFontFamily,
            onChanged: controller.setCodeFontFamily,
          ),
        ),
        const SizedBox(height: 8),
        _SettingRow(
          title: 'Code font size',
          description: 'Set on its own, independent of the UI size',
          control: _SizeField(
            fieldKey: const Key('code-font-size'),
            value: prefs.codeFontSize,
            min: ChatPrefs.minCodeFontSize,
            max: ChatPrefs.maxCodeFontSize,
            onChanged: controller.setCodeFontSize,
          ),
        ),
        const SizedBox(height: 18),
        const _TypePreview(),
      ],
    );
  }
}

TextStyle _rowTitle() => TextStyle(
  fontFamily: AppFont.sans,
  fontFamilyFallback: AppFont.sansFallback,
  fontSize: 13,
  height: 1.2,
  fontWeight: AppFont.medium,
  color: AppPalette.textPrimary,
);

TextStyle _rowDescription() => TextStyle(
  fontFamily: AppFont.sans,
  fontFamilyFallback: AppFont.sansFallback,
  fontSize: 12,
  height: 1.28,
  color: AppPalette.textSecondary,
);

/// One preference, on its own raised row.
///
/// The row surface is the same recipe as `ExtensionTileSurface` in Plugins —
/// `AppGlass.surfaceFill` + `AppGlass.cardShadow`, radius 14 — so a setting here
/// sits at the same depth as a plugin or a skill elsewhere in Settings. No
/// border: rule 1 of the design system, and the shadow is what does the
/// separating anyway.
///
/// Unlike a Plugins row this one has no hover: nothing about the row is
/// clickable, only the control inside it, and a surface that lights up under the
/// pointer promises a target that isn't there.
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.description,
    required this.control,
  });

  final String title;
  final String description;
  final Widget control;

  /// The control column's width.
  ///
  /// Fixed, so all four controls share one left and one right edge — a column
  /// where each control shrink-wrapped its own content would step in and out and
  /// read as four unrelated widgets. Wide enough for the longest family name a
  /// picker is likely to hold ("Source Code Pro") without truncating.
  static const double controlWidth = 188;

  /// Below this the control moves under the text instead of beside it.
  ///
  /// [controlWidth] + the gap + enough left for the description to still be a
  /// sentence rather than one word per line. A narrowed window used to push the
  /// control straight off the row, which is a yellow-and-black overflow bar in
  /// debug and a clipped control in release.
  static const double _stackBelow = controlWidth + 20 + 130;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: _rowTitle()),
        const SizedBox(height: 3),
        Text(description, style: _rowDescription()),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < _stackBelow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    text,
                    const SizedBox(height: 10),
                    // Full width once stacked: a 188px control floating in a
                    // narrow row would read as misaligned rather than compact.
                    SizedBox(width: double.infinity, child: control),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: text),
                    const SizedBox(width: 20),
                    SizedBox(width: controlWidth, child: control),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The font family picker.
///
/// Offers the curated faces first, then every other family installed on this
/// Mac. A curated face this Mac doesn't have is dropped rather than shown
/// greyed: [AppSelectField] has no disabled row, and a row that looks pickable
/// but silently falls back is worse than one that isn't there. The exception is
/// a face the user has already chosen — if it later goes missing (prefs synced
/// from another Mac), it stays in the list, labelled, so they can see what the
/// app is trying to use and change it.
class _FontPicker extends StatelessWidget {
  const _FontPicker({
    super.key,
    required this.label,
    required this.curated,
    required this.installed,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<FontChoice> curated;
  final List<String> installed;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final options = buildFontOptions(curated: curated, installed: installed);
    final missing = !isFamilyInstalled(value, installed);
    // The chosen face may be in neither list — a name synced from a Mac that
    // had it, or one uninstalled since. It still gets a row, or the picker
    // would show some *other* font's name while the app renders a fallback,
    // and there would be no way to tell what went wrong.
    final orphaned =
        missing && !options.any((choice) => choice.family == value);

    return AppSelectField<String?>(
      label: label,
      // The settings row on the left already names this control. A second copy
      // above the field would repeat it *and* make the picker taller than the
      // size box beside it, which is what knocked the four controls out of
      // alignment with their own rows.
      showLabel: false,
      // Matches the size fields beside it, and picked per theme for the same
      // measured reason — see the note on _SizeField's decoration.
      fill: AppTheme.pick(AppPalette.cardBg, AppCard.inset),
      value: value,
      onChanged: onChanged,
      options: [
        if (orphaned)
          AppSelectOption<String?>(
            value: value,
            label: value!,
            detail: _missingDetail,
          ),
        for (final choice in options)
          // A curated face this Mac lacks is dropped — AppSelectField has no
          // disabled row, and one that looks pickable but silently falls back
          // is worse than one that isn't offered. The exception is the face
          // already in use, handled above and just below.
          if (choice.detail != _notInstalled || choice.family == value)
            AppSelectOption<String?>(
              value: choice.family,
              label: choice.label,
              detail: choice.family == value && missing
                  ? _missingDetail
                  : choice.detail,
            ),
      ],
    );
  }

  /// What [buildFontOptions] marks an uninstalled curated face with.
  static const _notInstalled = 'Not installed';

  /// What the picker says about the face it is *currently set to* when this Mac
  /// doesn't have it — wordier than [_notInstalled] on purpose, since this one
  /// is telling the user their setting isn't taking effect.
  static const _missingDetail = 'Not installed on this Mac';
}

/// A font size, typed as a number with a `px` suffix — the same control Codex
/// uses, and the one a size wants: a slider hides the actual value, and this is
/// a setting people copy between machines by reading the number off.
///
/// Commits on Enter and on losing focus, never per keystroke: typing "9" on the
/// way to "19" would otherwise resize the whole app for a moment, moving the
/// very field being typed in. Out-of-range input snaps to the nearest bound
/// rather than being rejected, and the field is rewritten to what was actually
/// stored so it can never disagree with the app.
class _SizeField extends StatefulWidget {
  const _SizeField({
    required this.fieldKey,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  /// Goes on the inner [TextField], not on this widget: what a caller — and a
  /// test — wants to reach is the box being typed in.
  final Key fieldKey;

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  State<_SizeField> createState() => _SizeFieldState();
}

class _SizeFieldState extends State<_SizeField> {
  late final TextEditingController _controller = TextEditingController(
    text: _format(widget.value),
  );
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_SizeField old) {
    super.didUpdateWidget(old);
    // The stored value can move without this field being the cause — a reset,
    // or the other end of a clamp. Don't fight the user mid-edit, though.
    if (widget.value != old.value && !_focus.hasFocus) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Whole numbers render without a trailing `.0` — "12", not "12.0" — but a
  /// half step survives, since the app's own code default is 12.5.
  static String _format(double value) =>
      value == value.roundToDouble() ? value.round().toString() : '$value';

  void _commit() {
    final parsed = double.tryParse(_controller.text.trim());
    // Unparseable input reverts rather than resetting to a default: the user
    // typed something, and throwing away their current size for a typo would be
    // a worse answer than ignoring the typo.
    final next = parsed == null
        ? widget.value
        : parsed.clamp(widget.min, widget.max).toDouble();
    _controller.text = _format(next);
    if (next != widget.value) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Right-aligned in the control column rather than stretched across it: a
    // two-character number in a 188px box reads as an empty field waiting to be
    // filled, and the field's right edge is what has to line up with the
    // pickers' — a stretched box would line up too, but by being four times
    // wider than the value it holds.
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 96,
        child: TextField(
          key: widget.fieldKey,
          controller: _controller,
          focusNode: _focus,
          textAlign: TextAlign.center,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          onSubmitted: (_) => _commit(),
          style: const TextStyle(fontSize: 14, height: 1.4),
          decoration:
              labeledFieldDecoration(
                '',
                // Picked per theme, because the two tokens rank differently
                // against a raised row and picking one for both leaves the
                // field invisible in whichever theme lost. Measured against
                // AppGlass.surfaceFill:
                //
                //   dark   inset #181818  1.090  ·  cardBg #1E1E1E  1.023
                //   light  inset #F7F7F5  1.073  ·  cardBg #F3F3F2  1.110
                //
                // So dark takes `inset` and light takes `cardBg` — the same
                // shape of fix the dialogs needed, and the reason the default
                // can't simply be left alone here.
                fill: AppTheme.pick(AppPalette.cardBg, AppCard.inset),
              ).copyWith(
                // The unit rides inside the field instead of floating beside
                // it: outside, it pushed the box off the column's right edge
                // and read as a stray word on the row.
                suffixText: 'px',
                suffixStyle: TextStyle(
                  fontFamily: AppFont.sans,
                  fontFamilyFallback: AppFont.sansFallback,
                  fontSize: 12,
                  color: AppPalette.textFaint,
                ),
                contentPadding: const EdgeInsets.fromLTRB(12, 13, 10, 13),
              ),
        ),
      ),
    );
  }
}

/// What the settings above actually look like.
///
/// Both faces at once, because the point of the pair is how they sit together:
/// a sentence of UI prose over a block of code, which is the shape of nearly
/// every screen in the app. The code half wears the real code surface — the
/// recessed fill and its own size, out of the UI scale — so what's shown here is
/// what a chat's code block will be.
class _TypePreview extends StatelessWidget {
  const _TypePreview();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        // Radius 14, the row radius — the preview is a block in the same stack,
        // not a card from a different system.
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Preview', style: _rowTitle()),
          const SizedBox(height: 10),
          // A turn of an answer, at the size a turn is actually set at
          // (bodyMedium, 15) — not a lone specimen line. The point of the
          // pairing is that prose and code sit together on this scale.
          Text(
            'Here is how a reply reads, and the code inside one:',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textPrimary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          // The real widget, not a mock-up of it.
          //
          // Drawing a lookalike here was the flaw: a plain box of white mono
          // showed neither the header, the copy action, nor the syntax colour a
          // chat's block actually has — so it under-sold the setting *and* it
          // could drift from the thing it claims to preview. MarkdownCodeBlock
          // is what a transcript builds, so what's shown is what will render.
          //
          // `closed: true` because this fragment is complete: that flag is the
          // block's "still streaming" state, and it is what gates the Copy
          // button and the highlighting on.
          const MarkdownCodeBlock(
            language: 'python',
            code: _sampleCode,
            closed: true,
          ),
        ],
      ),
    );
  }

  /// The specimen.
  ///
  /// Chosen to exercise what a code face is judged on rather than to do
  /// anything useful: `0O` and `1lI` adjacent, so a slashed zero and a tailed
  /// `l` are visible or their absence is; the bracket trio; the arrow and
  /// comparison pairs that a face drawn for code either handles or crowds. It
  /// is real Python so the highlighter has something to colour — a nonsense
  /// string would render as one flat ink and hide half of what the preview is
  /// for.
  static const _sampleCode = '''
def fetch(urls: list[str], retries: int = 3) -> dict:
    # 0O 1lI — check the zero, the one, the ell
    for attempt in range(retries):
        if (resp := get(urls[0])) and resp.ok:
            return {"data": resp.json(), "tries": attempt + 1}
    raise TimeoutError(f"{urls[0]} failed after {retries} tries")''';
}
