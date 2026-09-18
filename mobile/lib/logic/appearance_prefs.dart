/// How the phone's copy of Grid looks, and where that choice is kept.
///
/// Its own store rather than a corner of [PairedHostStore]: that one holds a
/// bearer credential for somebody's computer and lives in the Keychain for
/// exactly that reason, where an entry outlives an uninstall and goes wherever
/// the Keychain is told to. How big the text is is a preference — it belongs in
/// the platform's own defaults, cleared with the app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The size the phone app is drawn at — scale 1.0, the shipped look. Matches
/// the Mac's base, because both apps resolve one text theme out of `grid_theme`
/// and a different base here would mean "Default" wore two different sizes.
const double kDefaultUiSize = 13;

/// What code is set at when nobody has chosen — [AppFont]'s own default.
const double kDefaultCodeSize = 12.5;

/// The sizes the app offers, smallest first.
///
/// Steps rather than the Mac's typed number. That control exists because a size
/// is a value people read off one machine and type into another; on a phone it
/// is a number pad in front of the thing being resized. Four steps are a tap
/// each and the app itself is the preview.
///
/// The range is the phone's own, and wider at the top than the Mac's ±35%: the
/// rows here are built from padding rather than from the fixed-height control
/// boxes that cap the desktop, so a larger label grows its row instead of being
/// clipped by it.
const List<({String label, double size})> kUiSizeSteps = [
  (label: 'Small', size: 12),
  (label: 'Default', size: kDefaultUiSize),
  (label: 'Large', size: 15),
  (label: 'Larger', size: 17),
];

/// The code sizes on offer. Wider at the bottom than the UI's, for the reason
/// the Mac gives: a code block is a self-contained box that can go smaller
/// without dragging a row's geometry with it.
const List<({String label, double size})> kCodeSizeSteps = [
  (label: 'Small', size: 11),
  (label: 'Default', size: kDefaultCodeSize),
  (label: 'Large', size: 14),
  (label: 'Larger', size: 16),
];

/// Everything the Appearance screen owns.
@immutable
class Appearance {
  const Appearance({
    this.themeMode = ThemeMode.system,
    this.uiSize = kDefaultUiSize,
    this.codeSize = kDefaultCodeSize,
    this.uiFamily,
    this.codeFamily,
  });

  /// Light, dark, or whatever the phone is set to.
  final ThemeMode themeMode;

  /// The base size everything else scales against.
  final double uiSize;

  /// Code's own size, independent of [uiSize] so a larger UI doesn't drag code
  /// blocks with it.
  final double codeSize;

  /// The chosen UI face, or null for the system's own.
  final String? uiFamily;

  /// The chosen code face, or null for the system's own monospaced.
  final String? codeFamily;

  /// What every UI size is multiplied by, against the size the app was drawn
  /// at — so 1.0 is exactly the shipped look.
  double get uiScale => uiSize / kDefaultUiSize;

  Appearance copyWith({
    ThemeMode? themeMode,
    double? uiSize,
    double? codeSize,
    // Sentinels, because null is a real value for both: it means "the system's
    // own face", and `family ?? this.family` could never set it back.
    Object? uiFamily = _keep,
    Object? codeFamily = _keep,
  }) => Appearance(
    themeMode: themeMode ?? this.themeMode,
    uiSize: uiSize ?? this.uiSize,
    codeSize: codeSize ?? this.codeSize,
    uiFamily: uiFamily == _keep ? this.uiFamily : uiFamily as String?,
    codeFamily: codeFamily == _keep ? this.codeFamily : codeFamily as String?,
  );

  static const Object _keep = Object();

  /// Value equality so a re-read that changed nothing rebuilds nothing — this
  /// is provider state, and the whole app rebuilds when it moves.
  @override
  bool operator ==(Object other) =>
      other is Appearance &&
      other.themeMode == themeMode &&
      other.uiSize == uiSize &&
      other.codeSize == codeSize &&
      other.uiFamily == uiFamily &&
      other.codeFamily == codeFamily;

  @override
  int get hashCode =>
      Object.hash(themeMode, uiSize, codeSize, uiFamily, codeFamily);
}

/// Reads and writes the look, one key per setting.
class AppearanceStore {
  const AppearanceStore();

  static const _theme = 'grid.appearance.themeMode';
  static const _uiSize = 'grid.appearance.uiSize';
  static const _codeSize = 'grid.appearance.codeSize';
  static const _uiFamily = 'grid.appearance.uiFamily';
  static const _codeFamily = 'grid.appearance.codeFamily';

  /// What was saved, or the defaults — including when the platform refuses the
  /// read, because a phone that cannot read a preference has not chosen one.
  Future<Appearance> read() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on Object {
      return const Appearance();
    }
    return Appearance(
      themeMode: _themeFrom(prefs.getString(_theme)),
      uiSize: _sizeFrom(prefs.getDouble(_uiSize), kUiSizeSteps, kDefaultUiSize),
      codeSize: _sizeFrom(
        prefs.getDouble(_codeSize),
        kCodeSizeSteps,
        kDefaultCodeSize,
      ),
      uiFamily: prefs.getString(_uiFamily),
      codeFamily: prefs.getString(_codeFamily),
    );
  }

  /// Keeps [next] for the next launch. A write that fails is not worth failing
  /// a tap over: the choice still applies to this session, and the next launch
  /// falls back to where it started.
  Future<void> write(Appearance next) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_theme, next.themeMode.name);
      await prefs.setDouble(_uiSize, next.uiSize);
      await prefs.setDouble(_codeSize, next.codeSize);
      await _family(prefs, _uiFamily, next.uiFamily);
      await _family(prefs, _codeFamily, next.codeFamily);
    } on Object {
      return;
    }
  }

  /// Removed rather than written empty: "" and "the system's own face" are
  /// different claims, and only one of them is what null means.
  Future<void> _family(SharedPreferences prefs, String key, String? value) =>
      value == null ? prefs.remove(key) : prefs.setString(key, value);

  static ThemeMode _themeFrom(String? stored) {
    for (final mode in ThemeMode.values) {
      if (mode.name == stored) return mode;
    }
    return ThemeMode.system;
  }

  /// A stored size that is not one this build offers reads as the default — a
  /// step list can change between releases, and an off-list size would leave
  /// the picker showing nothing selected.
  static double _sizeFrom(
    double? stored,
    List<({String label, double size})> steps,
    double fallback,
  ) => steps.any((step) => step.size == stored) ? stored! : fallback;
}

/// How the app looks. Written by the Appearance rows in Settings, read by the
/// one [MaterialApp] at the root.
class AppearanceController extends Notifier<Appearance> {
  final _store = const AppearanceStore();

  @override
  Appearance build() {
    // Outside the constructor, not in it: this is a side effect, and `build`
    // runs again for reasons that have nothing to do with wanting a second
    // read. Until it lands the app wears the shipped look, which is the right
    // thing to be wearing for a frame — anything else flashes.
    _restore();
    return const Appearance();
  }

  Future<void> _restore() async => state = await _store.read();

  /// Applies [next] now, and at the next launch.
  Future<void> apply(Appearance next) async {
    if (next == state) return;
    state = next;
    await _store.write(next);
  }
}

/// The app's look.
final appearanceProvider = NotifierProvider<AppearanceController, Appearance>(
  AppearanceController.new,
);

/// Just the theme, for the widgets that only care about that — a size change
/// must not rebuild something watching for light/dark.
final themeModeProvider = Provider<ThemeMode>(
  (ref) => ref.watch(appearanceProvider.select((a) => a.themeMode)),
);
