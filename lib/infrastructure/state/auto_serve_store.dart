import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// Whether opening the app also puts this computer to work, and on what.
///
/// **Off until the user asks.** Serving spends their own GPU and battery, so
/// the app starting an engine on every launch would be spending their machine
/// without permission — the reason there was no launch hook at all before
/// this. A ticked box is that permission, given once, for one named model on
/// one named grid: [model] and [networkId] are stored rather than re-derived
/// at launch, so "start what I chose" can't quietly become "start whatever
/// happens to be first in the list".
class AutoServePrefs {
  const AutoServePrefs({
    this.enabled = false,
    this.networkId,
    this.model,
    this.advertiseAs,
    this.ctxSize,
  });

  final bool enabled;

  /// The grid to join. Nothing starts on a different one — the user chose this
  /// model *for this grid*.
  final String? networkId;

  /// The GGUF filename to serve (a split model's first shard).
  final String? model;

  /// The name the grid shows. Null falls back to the one derived from [model].
  final String? advertiseAs;

  /// Context window in tokens. Null leaves the model's own default in place.
  final int? ctxSize;

  /// Whether this is actually startable, as opposed to merely switched on. A
  /// prefs file naming no model can't start anything, and reading it as "on"
  /// would put a tick in a box that does nothing.
  bool get isArmed =>
      enabled &&
      (model?.isNotEmpty ?? false) &&
      (networkId?.isNotEmpty ?? false);

  AutoServePrefs copyWith({
    bool? enabled,
    String? networkId,
    String? model,
    String? advertiseAs,
    int? ctxSize,
  }) => AutoServePrefs(
    enabled: enabled ?? this.enabled,
    networkId: networkId ?? this.networkId,
    model: model ?? this.model,
    advertiseAs: advertiseAs ?? this.advertiseAs,
    ctxSize: ctxSize ?? this.ctxSize,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    if (networkId != null) 'network_id': networkId,
    if (model != null) 'model': model,
    if (advertiseAs != null) 'advertise_as': advertiseAs,
    if (ctxSize != null) 'ctx_size': ctxSize,
  };

  static AutoServePrefs fromJson(Map<String, dynamic> json) {
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    final ctx = json['ctx_size'];
    return AutoServePrefs(
      enabled: json['enabled'] == true,
      networkId: text(json['network_id']),
      model: text(json['model']),
      advertiseAs: text(json['advertise_as']),
      ctxSize: (ctx is int && ctx > 0) ? ctx : null,
    );
  }
}

/// Reads and writes `~/.grid/app/auto_serve.json`.
///
/// Lenient like the other app stores: a missing or unreadable file reads as
/// "don't start anything", which is the safe answer either way.
class AutoServeStore {
  AutoServeStore({File? file}) : _file = file ?? GridPaths.autoServeFile;

  final File _file;

  AutoServePrefs load() {
    try {
      if (!_file.existsSync()) return const AutoServePrefs();
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return const AutoServePrefs();
      return AutoServePrefs.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      return const AutoServePrefs();
    }
  }

  void save(AutoServePrefs prefs) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(prefs.toJson()),
      flush: true,
    );
  }
}

/// Overridable so tests point at a temp file, never the real `~/.grid`.
final autoServeStoreProvider = Provider<AutoServeStore>(
  (ref) => AutoServeStore(),
);

/// This computer's start-on-open setting. Every change persists.
final autoServePrefsProvider =
    NotifierProvider<AutoServeController, AutoServePrefs>(
      AutoServeController.new,
    );

class AutoServeController extends Notifier<AutoServePrefs> {
  @override
  AutoServePrefs build() => ref.read(autoServeStoreProvider).load();

  /// Turn it on for exactly this model on exactly this grid, or off.
  ///
  /// Turning it off keeps the rest of the record: the box is far more often
  /// unticked to skip one session than to forget the choice, and re-ticking it
  /// should not be a second round of picking a model.
  void set({
    required bool enabled,
    required String networkId,
    required String model,
    String? advertiseAs,
    int? ctxSize,
  }) => _write(
    AutoServePrefs(
      enabled: enabled,
      networkId: networkId,
      model: model,
      advertiseAs: advertiseAs,
      ctxSize: ctxSize,
    ),
  );

  /// Keeps the armed model's stored name and context window in step with the
  /// form the user is editing, so a launch serves what the engine block shows.
  ///
  /// Deliberately narrow: it refreshes the record for the model the tick was
  /// made for and refuses to point it anywhere else. Moving the target is the
  /// checkbox's job, and a "follow whatever is selected" version would rearm on
  /// a model the user was only looking at.
  void refresh({
    required String networkId,
    required String model,
    String? advertiseAs,
    int? ctxSize,
  }) {
    if (!state.enabled) return;
    if (state.networkId != networkId || state.model != model) return;
    if (state.advertiseAs == advertiseAs && state.ctxSize == ctxSize) return;
    set(
      enabled: true,
      networkId: networkId,
      model: model,
      advertiseAs: advertiseAs,
      ctxSize: ctxSize,
    );
  }

  void _write(AutoServePrefs prefs) {
    state = prefs;
    ref.read(autoServeStoreProvider).save(prefs);
  }
}
