import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';

/// A starter card's rim width. Its border sits *outside* the card's content
/// box, so the grid has to count it when it works out whether four cards fit —
/// shared here so the layout math and the card that draws the rim can't drift.
const double _starterCardRim = 1.5;

/// The title's font size and line-height factor, named so the card can reserve
/// exactly two lines of it: a one- and a two-line title then leave their
/// descriptions on the same row instead of one shoving the other down.
const double _titleFontSize = 14;
const double _titleHeightFactor = 1.16;

/// A fresh chat's empty state: a greeting and four things to try. Tapping one
/// drops its prompt into the composer, so a first-time user has something to send
/// instead of a blank box and a blinking cursor.
class ChatStarters extends StatelessWidget {
  const ChatStarters({super.key, required this.greeting, required this.onPick});

  final String greeting;

  /// Called with the tapped starter's prompt, to prefill the composer.
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette tokens (the subtitle) — follow theme flips.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final cardWidth = (compact ? 166 : 178) * AppFont.uiScale;
        // Four cards want a 4-up strip or a 2×2 grid — never the ragged 3+1 a
        // Wrap produces when a fourth card is 20px shy of fitting. Decide the
        // shape from the width the cards *actually* occupy (they scale with the
        // UI font, so a hard 760 stopped matching them the moment the user sized
        // type up), and stretch the content box to match that choice so the row
        // is centred on real content, not on a constant that no longer fits.
        const gap = 12.0;
        // A card's painted width is its content box plus the 1.5px rim on each
        // side (_StarterCard's Border.all sits outside the SizedBox). Leave that
        // out and four cards overrun the row by 4×3px — the exact 3+1-looking
        // overflow this layout exists to prevent.
        const rimTotal = _starterCardRim * 2;
        final cardOuter = cardWidth + rimTotal;
        final fourUpWidth = cardOuter * 4 + gap * 3;
        final twoUpWidth = cardOuter * 2 + gap;
        final fourUp = constraints.maxWidth >= fourUpWidth + 48;
        final rowWidth = fourUp ? fourUpWidth : twoUpWidth;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, compact ? 34 : 66, 24, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: rowWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _Glyph(),
                  const SizedBox(height: 20),
                  Text(
                    greeting,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: compact ? 27 : 31,
                      // Semibold at 31pt, not bold. Size already carries all
                      // the emphasis a greeting needs — past ~28pt the weight
                      // stops adding rank and just adds ink, and this is the
                      // largest type in the app, so it was the heaviest thing
                      // on the screen by a wide margin.
                      fontWeight: AppFont.semibold,
                      height: 1.06,
                      // Less negative than -0.4: tight tracking on large type
                      // is a display-face trick, and it was doing to a whole
                      // sentence what it's meant to do to a two-word logotype —
                      // packing the letters until the line reads as one mass.
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    'Pick a starting point, or just start typing.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.3,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 30),
                  _StarterGrid(
                    starters: _starters,
                    cardWidth: cardWidth,
                    gap: gap,
                    fourUp: fourUp,
                    onPick: onPick,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The four starter cards, laid out as one row of four or a 2×2 block — the two
/// shapes that stay balanced for exactly four items. A Wrap was used before and
/// gave a lop-sided 3+1 whenever the fourth card fell a hair short of the row.
class _StarterGrid extends StatelessWidget {
  const _StarterGrid({
    required this.starters,
    required this.cardWidth,
    required this.gap,
    required this.fourUp,
    required this.onPick,
  });

  final List<_Starter> starters;
  final double cardWidth;
  final double gap;
  final bool fourUp;
  final ValueChanged<String> onPick;

  Widget _card(_Starter starter) => _StarterCard(
    starter: starter,
    width: cardWidth,
    onTap: () => onPick(starter.prompt),
  );

  Widget _row(List<_Starter> row) => Row(
    mainAxisSize: MainAxisSize.min,
    // Not stretch: the cards set their own fixed height, and stretching a Row
    // that has no bounded height of its own asks each card to be infinitely
    // tall. Equal heights come from the cards themselves, not the row.
    children: [
      for (var i = 0; i < row.length; i++) ...[
        if (i > 0) SizedBox(width: gap),
        _card(row[i]),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (fourUp) return _row(starters);
    // 2×2: split down the middle so each row holds two, and the rows are the
    // same width — no orphaned card on a line of its own.
    final half = (starters.length / 2).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _row(starters.sublist(0, half)),
        SizedBox(height: gap),
        _row(starters.sublist(half)),
      ],
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph();

  @override
  Widget build(BuildContext context) {
    // Follow the theme so this mark re-tints on a Light/Dark flip.
    AppTheme.watch(context);
    // The brand bolt in a soft indigo→violet chip — Grid's own mark, and the one
    // spot of colour up here. A grey cloud said nothing about code; the bolt ties
    // the greeting to the app and gives the empty state a warm focal point.
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppPalette.accent,
            Color.lerp(AppPalette.accent, const Color(0xFF7A3CF0), 0.5)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: AppPalette.accent.withValues(alpha: 0.38),
            blurRadius: 20,
            offset: const Offset(0, 8),
            spreadRadius: -8,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: const Icon(
        LucideIcons.zap,
        size: 25,
        color: Colors.white,
        semanticLabel: 'Grid',
      ),
    );
  }
}

/// One thing the chat is good at, with the prompt it drops into the composer.
class _Starter {
  const _Starter({
    required this.icon,
    required this.lightColor,
    required this.darkColor,
    required this.title,
    required this.description,
    required this.prompt,
  });

  final IconData icon;

  /// The accent colours, per surface — the dark values are lifted so the chip and
  /// icon keep their contrast on charcoal instead of muddying.
  final Color lightColor;
  final Color darkColor;
  final String title;

  /// A quiet second line under the title — says what the card actually does, so
  /// each one reads as an offer rather than just a label.
  final String description;
  final String prompt;

  /// The starter's accent for the live theme.
  Color get color => AppTheme.pick(lightColor, darkColor);
}

const _starters = [
  _Starter(
    icon: LucideIcons.sparkles,
    lightColor: Color(0xFF2F80ED),
    darkColor: Color(0xFF5B9BF5),
    title: 'Ask a question',
    description: 'Get a clear, simple answer',
    prompt: 'I have a question: ',
  ),
  _Starter(
    icon: LucideIcons.penLine,
    lightColor: Color(0xFF8A3FFC),
    darkColor: Color(0xFFA66CFF),
    title: 'Write something',
    description: 'An email, message, or note',
    prompt: 'Help me write ',
  ),
  _Starter(
    icon: LucideIcons.fileText,
    lightColor: Color(0xFF16A34A),
    darkColor: Color(0xFF35C46B),
    title: 'Understand a document',
    description: 'Summarize or explain it',
    prompt: 'Explain this in plain language:\n\n',
  ),
  _Starter(
    icon: LucideIcons.listChecks,
    lightColor: Color(0xFFF97316),
    darkColor: Color(0xFFFB9A4B),
    title: 'Plan something',
    description: 'A trip, event, or to-do list',
    prompt: 'Help me plan ',
  ),
];

/// One tappable suggestion card.
class _StarterCard extends StatefulWidget {
  const _StarterCard({
    required this.starter,
    required this.width,
    required this.onTap,
  });

  final _Starter starter;
  final double width;
  final VoidCallback onTap;

  @override
  State<_StarterCard> createState() => _StarterCardState();
}

class _StarterCardState extends State<_StarterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Reads AppCard/AppGlass tokens — follow theme flips even when not hovering.
    AppTheme.watch(context);
    final radius = BorderRadius.circular(16);
    // On hover the card lifts: it tints its rim to the starter's own colour,
    // deepens the shadow, and rises a couple of pixels — so it reads as a real,
    // pickable surface instead of a ghost on the near-white pane.
    final borderColor = _hovered
        ? widget.starter.color.withValues(alpha: 0.55)
        : AppGlass.hair;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        // Rise on hover — a paint transform, so neighbours never shift.
        transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppCard.base,
          borderRadius: radius,
          // Rim stays 1.5px at rest and on hover — only its colour animates, so
          // the content never nudges by the half-pixel a width change would add.
          border: Border.all(color: borderColor, width: _starterCardRim),
          boxShadow: _hovered ? AppCard.shadow : AppGlass.cardShadow,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            hoverColor: Colors.transparent,
            child: SizedBox(
              width: widget.width,
              // Tall enough for the worst case: a two-line title over a two-line
              // description, with the icon chip above both.
              //
              // Scaled, because "the worst case" is a function of the user's UI
              // size. At 19px the titles that wrapped to two lines overflowed a
              // fixed 142 by exactly the extra line — the card is one of the few
              // places in the app that pins a height to text it doesn't measure.
              // Sized for the worst case now that the text block is rigid
              // rather than Spacer-cushioned: icon + a fixed gap + two lines of
              // title + two lines of description all have to fit without the
              // Spacer that used to soak up the slack. 152 clears it across the
              // whole UI-size range; smaller sizes leave a little air at the foot.
              height: 152 * AppFont.uiScale,
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 16, 16, 15) * AppFont.uiScale,
                child: _StarterContent(
                  starter: widget.starter,
                  hovered: _hovered,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StarterContent extends StatelessWidget {
  const _StarterContent({required this.starter, required this.hovered});

  final _Starter starter;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette tokens — follow theme flips.
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The icon sits in a soft tinted chip — a small spot of the starter's
        // colour that gives each card a point of focus and lifts it off the
        // pane. It swells a hair on hover so the card feels responsive.
        AnimatedScale(
          scale: hovered ? 1.06 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.topLeft,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: starter.color.withValues(alpha: hovered ? 0.20 : 0.13),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(starter.icon, size: 18, color: starter.color),
          ),
        ),
        // A fixed gap, not a Spacer. A Spacer pins the text to the card's
        // bottom, so a card whose title wraps to two lines pushes its whole text
        // block *upward*, and four cards side by side then have their titles on
        // different lines. A set distance puts every title on the same baseline.
        SizedBox(height: 10 * AppFont.uiScale),
        // The title reserves two lines' height whether it needs them or not, so
        // a one-line title and a two-line one leave their descriptions at the
        // same y — the second line grows *down* into space already held, instead
        // of pushing the description around. maxLines caps it; the box height is
        // what keeps the row below it aligned.
        SizedBox(
          height: _titleFontSize * _titleHeightFactor * 2 * AppFont.uiScale,
          child: Text(
            starter.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _titleFontSize,
              height: _titleHeightFactor,
              letterSpacing: -0.1,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 3),
        // The quiet second line — says what the card actually offers, so it gets
        // the card's full width and wraps rather than truncating. Nothing shares
        // this row: the hover lift, the tinted rim and the click cursor already
        // say the card is pickable, so an arrow cue here would only cost text.
        Text(
          starter.description,
          maxLines: 2,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.3,
            color: AppPalette.textFaint,
          ),
        ),
      ],
    );
  }
}
