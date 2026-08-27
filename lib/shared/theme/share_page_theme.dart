import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The Share Intelligence mockup's own palette and type, to the value.
///
/// A second palette in one app is a drift risk (§5), and this one is here on
/// purpose: the design for that page is a *cooler* family than [AppPalette] —
/// blue-grey inks at hue 265 where the app runs warm at `#62615B`, a deeper
/// accent, and hairlines several shades darker than the app's 6% black, which
/// on white is nearly invisible. Matching it by nudging [AppPalette] would
/// restyle every screen in the app; matching it here restyles the page that was
/// designed.
///
/// **TODO(BE): four of these inks are under §11's 4.5:1 floor**, measured on
/// this page's own two grounds (`#F9FAFB` rail / `#FDFDFF` card):
///
/// ```
///   line    #74777F   4.29 / 4.41    route card description, 12.3px
///   note    #777A82   4.11 / 4.23    status note, field helper, 12px
///   helper  #7D8088   3.78 / 3.89    footnote and button helper, 11.5–12.5px
///   eyebrow #83868E   3.49 / 3.59    CHOOSE A ROUTE, ROUTE 01, 10.5px
/// ```
///
/// They are the mockup's values and they ship because the mockup is the brief.
/// The floor is not negotiable long-term: darkening each by roughly one step
/// (0.55/0.55/0.55/0.5 lightness) clears it and is invisible beside the
/// original. Decide it, don't inherit it.
///
/// Dark values are *derived*, not designed — the mockup is light-only. Each one
/// answers "what plays this role on a dark ground", taken from [AppPalette] so
/// the page stays coherent in a theme the design never covered.
abstract final class SharePalette {
  /// The ground the whole page sits on.
  static Color get pageBg =>
      AppTheme.pick(const Color(0xFFF6F7F9), const Color(0xFF181818));

  /// The rail, a shade above the page so the split reads without a heavy rule.
  static Color get railBg =>
      AppTheme.pick(const Color(0xFFF9FAFB), const Color(0xFF141414));

  /// Cards, plates and the status block.
  static Color get surface =>
      AppTheme.pick(const Color(0xFFFDFDFF), const Color(0xFF1E1E1E));

  /// The hairline round a card and down the middle of the page.
  static Color get rim =>
      AppTheme.pick(const Color(0xFFE1E3E6), const Color(0xFF2E2E2E));

  /// The rule *inside* a plate, one shade lighter than its own rim.
  static Color get innerRule =>
      AppTheme.pick(const Color(0xFFE8E9ED), const Color(0xFF282828));

  /// The rule above the rail's footnote.
  static Color get footRule =>
      AppTheme.pick(const Color(0xFFE4E6EA), const Color(0xFF2A2A2A));

  /// The unfilled half of a slider's track. A shade under [rim]: the track is
  /// a surface the thumb runs over, not an edge round a card.
  static Color get track =>
      AppTheme.pick(const Color(0xFFE0E1E5), const Color(0xFF313131));

  /// A field's own rim and fill — visible at rest, unlike the app's borderless
  /// capsule.
  static Color get fieldRim =>
      AppTheme.pick(const Color(0xFFDCDEE1), const Color(0xFF343434));
  static Color get fieldFill =>
      AppTheme.pick(const Color(0xFFF9FAFB), const Color(0xFF262626));

  /// Headings and anything the reader is meant to read first.
  static Color get ink =>
      AppTheme.pick(const Color(0xFF1C1F25), const Color(0xFFF5F5F5));

  /// A field's label.
  static Color get labelInk =>
      AppTheme.pick(const Color(0xFF4A4D54), const Color(0xFFC9C9C9));

  /// Body copy: the rail's subtitle, a pane's paragraph.
  static Color get body =>
      AppTheme.pick(const Color(0xFF6E7279), const Color(0xFFA8A8A2));

  /// A route card's description.
  static Color get line =>
      AppTheme.pick(const Color(0xFF74777F), const Color(0xFF9E9E9A));

  /// A note under a control, and the sharing status' second line.
  static Color get note =>
      AppTheme.pick(const Color(0xFF777A82), const Color(0xFF9A9A96));

  /// The quiet line beside a button, and the rail's footnote.
  static Color get helper =>
      AppTheme.pick(const Color(0xFF7D8088), const Color(0xFF949490));

  /// Capitalised section labels, and a slider's end marks.
  static Color get eyebrow =>
      AppTheme.pick(const Color(0xFF83868E), const Color(0xFF8C8C88));

  /// The one blue on the page: a selected route, a link, the button that
  /// finishes the job.
  static Color get accent =>
      AppTheme.pick(const Color(0xFF2261DD), const Color(0xFF4C82F0));
  static Color get accentHover =>
      AppTheme.pick(const Color(0xFF0E4EC8), const Color(0xFF6C99F4));

  /// The ring round the selected route card.
  static Color get accentRing => accent.withValues(alpha: 0.14);

  /// Live: the dot, and the eyebrow over the live pane.
  static Color get liveDot =>
      AppTheme.pick(const Color(0xFF269E5F), const Color(0xFF3FB950));
  static Color get liveInk =>
      AppTheme.pick(const Color(0xFF007840), const Color(0xFF3FB950));

  /// Idle: the dot when nothing is reachable.
  static Color get idleDot =>
      AppTheme.pick(const Color(0xFFA8AEBB), const Color(0xFF6E6E6E));

  /// A route card's badge. The green pair is worn by one badge on the page —
  /// the server already running here.
  static Color get badgeFill =>
      AppTheme.pick(const Color(0xFFEDF0F6), const Color(0xFF2A2A2A));
  static Color get badgeInk =>
      AppTheme.pick(const Color(0xFF5F636C), const Color(0xFFB4B4B0));
  static Color get readyBadgeFill =>
      AppTheme.pick(const Color(0xFFD2F6DD), const Color(0xFF15321F));
  static Color get readyBadgeInk =>
      AppTheme.pick(const Color(0xFF006436), const Color(0xFF6FD68F));
}

/// The mockup's type scale, by the role each size plays rather than by number.
///
/// Sizes and letter-spacing are the design's own. They do not come from
/// [TextTheme] because the app's scale is a different one — matching the mockup
/// means saying what it says.
abstract final class ShareType {
  /// The rail's headline: "Put this computer to work."
  static TextStyle get railTitle => TextStyle(
    fontSize: 27,
    height: 1.12,
    fontWeight: AppFont.semibold,
    letterSpacing: -0.028 * 27,
    color: SharePalette.ink,
  );

  /// The rail's paragraph under it.
  static TextStyle get railBody =>
      TextStyle(fontSize: 13.5, height: 1.5, color: SharePalette.body);

  /// A pane's headline: "Run a model on this computer."
  static TextStyle get paneTitle => TextStyle(
    fontSize: 22,
    fontWeight: AppFont.semibold,
    letterSpacing: -0.022 * 22,
    color: SharePalette.ink,
  );

  /// A pane's paragraph.
  static TextStyle get paneBody =>
      TextStyle(fontSize: 13.5, height: 1.55, color: SharePalette.body);

  /// CHOOSE A ROUTE · ROUTE 01 · LIVE ON THE GRID.
  static TextStyle get eyebrow => TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.1 * 10.5,
    color: SharePalette.eyebrow,
  );

  /// A route card's title, and the status block's.
  static TextStyle get cardTitle => TextStyle(
    fontSize: 13.5,
    fontWeight: AppFont.semibold,
    letterSpacing: -0.01 * 13.5,
    color: SharePalette.ink,
  );

  /// A route card's description.
  static TextStyle get cardLine =>
      TextStyle(fontSize: 12.3, height: 1.45, color: SharePalette.line);

  /// The sharing status' title.
  static TextStyle get statusTitle => TextStyle(
    fontSize: 12.5,
    fontWeight: AppFont.semibold,
    color: SharePalette.ink,
  );

  /// The sharing status' second line, and a helper under a field.
  static TextStyle get note =>
      TextStyle(fontSize: 12, height: 1.45, color: SharePalette.note);

  /// The rail's closing note.
  static TextStyle get footnote =>
      TextStyle(fontSize: 11.5, height: 1.5, color: SharePalette.helper);

  /// The line that sits beside a button.
  static TextStyle get buttonHelper =>
      TextStyle(fontSize: 12.5, color: SharePalette.helper);

  /// A field's label.
  static TextStyle get fieldLabel => TextStyle(
    fontSize: 12,
    fontWeight: AppFont.semibold,
    color: SharePalette.labelInk,
  );

  /// A badge on a route card.
  static TextStyle get badge => TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.06 * 10,
    height: 1.2,
  );
}

/// The mockup's metrics. Named so a number is written once and read where it is
/// used, rather than typed into six widgets that then drift apart.
abstract final class ShareMetrics {
  static const double railWidth = 396;
  static const EdgeInsets railPadding = EdgeInsets.fromLTRB(28, 34, 28, 28);
  static const EdgeInsets panePadding = EdgeInsets.fromLTRB(40, 34, 40, 40);

  /// Between the rail's blocks, and between a pane's.
  static const double railGap = 26;
  static const double paneGap = 24;

  /// Card radii: the plate, a route card, the status block, a field, a badge.
  static const double plateRadius = 13;
  static const double cardRadius = 11;
  static const double statusRadius = 10;
  static const double fieldRadius = 9;
  static const double badgeRadius = 5;

  /// A plate's own sections.
  static const EdgeInsets plateSection = EdgeInsets.fromLTRB(20, 18, 20, 18);

  /// A button, and the gap to the line beside it.
  static const double buttonHeight = 38;
  static const double buttonGap = 14;
}
