/// The font families this phone has, and the short list Grid vouches for.
///
/// The platform half only. How a list of families becomes the rows a picker
/// offers lives in `grid_theme` — [buildFontOptions] — because the Mac and the
/// phone must decide that the same way: a face the device does not have is
/// dropped, never offered to silently render as something else.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

/// Asks iOS what it has.
class PhoneFonts {
  const PhoneFonts._();

  /// The same channel name and reply shape the Mac's runner answers, so one
  /// Dart implementation serves both.
  static const MethodChannel _channel = MethodChannel('grid/fonts');

  /// The families installed on this phone, sorted, Apple's internal
  /// dot-prefixed faces filtered out by the native side.
  ///
  /// Empty on any failure — including a build whose runner predates the
  /// channel. The pickers then offer "System" alone, which is true: nothing
  /// else has been confirmed to exist.
  static Future<InstalledFonts> installedFamilies() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'availableFamilies',
      );
      if (result == null) return InstalledFonts.none;
      return InstalledFonts(
        all: List<String>.from(result['all'] as List? ?? const []),
        monospaced: List<String>.from(
          result['monospaced'] as List? ?? const [],
        ),
      );
    } on Object catch (error) {
      debugPrint('PhoneFonts: could not list installed families — $error');
      return InstalledFonts.none;
    }
  }
}

/// The UI faces worth putting at the top of the list.
///
/// Its own list, not the Mac's: Inter, Geist and Satoshi are faces somebody
/// installed on a desktop, and iOS installs nothing. These are the text faces
/// iOS has shipped with for years — and every one of them is still checked
/// against what the phone actually reports, so a guess that is wrong costs a
/// missing row rather than a lie.
const List<FontChoice> kPhoneUiFonts = [
  FontChoice(label: 'System', family: null, detail: 'SF Pro'),
  FontChoice(label: 'Helvetica Neue', family: 'Helvetica Neue'),
  FontChoice(label: 'Avenir Next', family: 'Avenir Next'),
  FontChoice(label: 'Georgia', family: 'Georgia'),
  FontChoice(label: 'Palatino', family: 'Palatino'),
  FontChoice(label: 'Times New Roman', family: 'Times New Roman'),
];

/// The code faces. Short, because a phone ships two fixed-pitch families worth
/// reading code in and inventing more would be offering names it does not have.
const List<FontChoice> kPhoneCodeFonts = [
  FontChoice(label: 'System Mono', family: null, detail: 'SF Mono'),
  FontChoice(label: 'Menlo', family: 'Menlo'),
  FontChoice(label: 'Courier New', family: 'Courier New'),
];

/// The installed families, fetched once per launch — the same list every picker
/// asks for, and a platform round-trip costs a frame.
final installedFontFamiliesProvider = FutureProvider<InstalledFonts>(
  (ref) => PhoneFonts.installedFamilies(),
);
