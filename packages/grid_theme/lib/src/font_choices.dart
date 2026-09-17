/// The vocabulary a font picker is built from, shared by both apps.
///
/// Pure: what a platform *has* is asked of that platform (a method channel per
/// runner — `NSFontManager` on the Mac, `UIFont.familyNames` on the phone), but
/// how a list of families becomes a list of offers is one rule, and it is the
/// rule that would drift. The Mac dropping a face it lacks while the phone
/// offered it and silently rendered something else is exactly the "never
/// promise a fallback works" bug, twice.
///
/// The curated lists stay with each app: the faces worth offering on a Mac are
/// not the faces a phone ships.
library;

import 'package:flutter/foundation.dart';

/// What this Mac has, split by what the two pickers can offer.
///
/// The split is made natively because only the font system can answer it: a
/// name-based guess ("does it say Mono?") misses Menlo and Courier and lets
/// Apple Symbols through — and a symbol font offered as a code face renders
/// source as pictograms.
@immutable
class InstalledFonts {
  const InstalledFonts({required this.all, required this.monospaced});

  /// No platform answer — a failed channel, or a widget test. The curated names
  /// still work; see [buildFontOptions].
  static const none = InstalledFonts(all: [], monospaced: []);

  /// Every browsable family, for the UI picker.
  final List<String> all;

  /// Just the fixed-pitch ones, for the code picker.
  final List<String> monospaced;

  /// The list one picker should offer.
  List<String> forCode(bool code) => code ? monospaced : all;
}

/// One offerable font.
@immutable
class FontChoice {
  const FontChoice({required this.label, required this.family, this.detail});

  /// What the row says. Not always the family name: the default is offered as
  /// "System" because that's what it *means* — `.AppleSystemUIFont` is an
  /// implementation detail the user shouldn't have to recognise.
  final String label;

  /// The family to hand CoreText, or null for the app's default stack.
  final String? family;

  /// A second line — what the face is for, or that it isn't installed.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is FontChoice &&
      other.label == label &&
      other.family == family &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(label, family, detail);
}

/// The full set of options for one of the two pickers: the curated names first,
/// then every other installed family.
///
/// A curated name that isn't installed still appears — marked, and disabled by
/// the picker — rather than vanishing. Silently dropping it would leave the
/// user wondering whether the app supports the font at all; saying "not
/// installed" answers that.
List<FontChoice> buildFontOptions({
  required List<FontChoice> curated,
  required List<String> installed,
}) {
  final installedSet = installed.toSet();
  final curatedFamilies = curated
      .map((choice) => choice.family)
      .whereType<String>()
      .toSet();

  return [
    for (final choice in curated)
      if (choice.family == null || installedSet.contains(choice.family))
        choice
      else
        FontChoice(
          label: choice.label,
          family: choice.family,
          detail: 'Not installed',
        ),
    for (final family in installed)
      if (!curatedFamilies.contains(family))
        FontChoice(label: family, family: family),
  ];
}

/// Whether a saved family is actually present on this Mac.
///
/// Worth surfacing: prefs travel between machines through a synced home
/// directory, and a font that resolved on one Mac silently falls back on
/// another. The picker says so rather than showing a name whose text is being
/// rendered in something else entirely.
bool isFamilyInstalled(String? family, List<String> installed) =>
    family == null || installed.contains(family);
