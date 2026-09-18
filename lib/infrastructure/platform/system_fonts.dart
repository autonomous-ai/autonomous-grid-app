import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

/// The fonts the Appearance screen can offer.
///
/// Two sources, deliberately: a short curated list the app vouches for, and
/// everything else installed on this Mac. The curated names come first because
/// a list of ~300 families sorted alphabetically is not a choice a user can
/// make — the ones worth picking have to be reachable without scrolling past
/// Al Nile and Apple Chancery.
///
/// Nothing here is bundled. The app ships no font files: every name below is
/// either a system face or something the user installed themselves, and one
/// that isn't installed is shown as unavailable rather than silently falling
/// back to a face that looks nothing like it.
class SystemFonts {
  const SystemFonts._();

  static const MethodChannel _channel = MethodChannel('grid/fonts');

  /// The families installed on this Mac, sorted, with Apple's internal
  /// dot-prefixed faces filtered out by the native side.
  ///
  /// Returns empty on any failure — a missing font list must degrade to "only
  /// the curated names are offered", never to a broken settings screen. The
  /// same is true under `flutter test`, where no platform side is listening.
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
      debugPrint('SystemFonts: could not list installed families — $error');
      return InstalledFonts.none;
    }
  }
}

/// The short list of UI faces the app vouches for, in the order they're offered.
///
/// System first and always available. The rest are the faces a desktop app is
/// actually set in — the ones Codex ships as theme fonts (Inter, Geist,
/// Satoshi) plus the two macOS has had forever — and each is offered only if
/// this Mac has it.
const List<FontChoice> kCuratedUiFonts = [
  // The detail is a pill in a control-width field, so it says the *fact* — which
  // face "System" resolves to — and nothing more. The sentence it used to carry
  // ("SF Pro — what the app is designed in") had nowhere to fit: it overflowed
  // the picker, and ellipsized it reads as a cut-off thought.
  FontChoice(label: 'System', family: null, detail: 'SF Pro'),
  FontChoice(label: 'Helvetica Neue', family: 'Helvetica Neue'),
  FontChoice(label: 'Inter', family: 'Inter'),
  FontChoice(label: 'Geist', family: 'Geist'),
  FontChoice(label: 'Satoshi', family: 'Satoshi'),
  FontChoice(label: 'Avenir Next', family: 'Avenir Next'),
  FontChoice(label: 'Arial', family: 'Arial'),
];

/// The curated code faces.
///
/// Monaco is offered but flagged: it has no slashed zero, so `0` and `O` are
/// nearly the same shape — which is the one thing a code font must not do to a
/// model id or a token. See [AppFont] for why the app's own default is SF Mono
/// with Menlo behind it.
const List<FontChoice> kCuratedCodeFonts = [
  // Same reason as the UI list: the pill names the face, and the preview below
  // the settings is where a slashed zero is actually judged.
  FontChoice(label: 'System Mono', family: null, detail: 'SF Mono'),
  FontChoice(label: 'Menlo', family: 'Menlo'),
  FontChoice(label: 'JetBrains Mono', family: 'JetBrains Mono'),
  FontChoice(label: 'Fira Code', family: 'Fira Code'),
  FontChoice(label: 'IBM Plex Mono', family: 'IBM Plex Mono'),
  FontChoice(label: 'Source Code Pro', family: 'Source Code Pro'),
  FontChoice(label: 'Courier New', family: 'Courier New'),
  FontChoice(label: 'Monaco', family: 'Monaco', detail: 'No slashed zero'),
];

/// The installed families, fetched once per launch.
///
/// A `FutureProvider` rather than a call in `initState`: the list is the same
/// for every screen that asks, the platform round-trip costs a frame, and
/// Riverpod already caches and shares it.
final installedFontFamiliesProvider = FutureProvider<InstalledFonts>(
  (ref) => SystemFonts.installedFamilies(),
);
