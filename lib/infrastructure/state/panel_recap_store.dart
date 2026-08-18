import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// How many finished turns are remembered per project.
///
/// Three, and the reason is the same one the reference gives: one turn is a
/// skewed picture. A project whose last turn happened to be "fixed a typo" reads
/// as a typo project, and the voice router then sends the next spoken sentence
/// somewhere else. Three turns is enough to show what someone is *working on*
/// and still short enough that every project's history fits in one prompt.
const int kPanelRecapsKept = 3;

/// One finished turn, as the panel was told about it.
class PanelTurnRecord {
  const PanelTurnRecord({
    required this.recap,
    required this.summary,
    required this.at,
  });

  /// The headline — at most fifteen words. Always present.
  final String recap;

  /// The longer form, when a model wrote one. Empty otherwise: a turn that ended
  /// with the cheap recap still counts as history, and dropping it would leave
  /// the router blind on exactly the machines where no model is reachable.
  final String summary;

  final DateTime at;

  Map<String, Object?> toJson() => {
    'recap': recap,
    if (summary.isNotEmpty) 'summary': summary,
    'at': at.toIso8601String(),
  };

  static PanelTurnRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final recap = '${raw['recap'] ?? ''}'.trim();
    if (recap.isEmpty) return null;
    return PanelTurnRecord(
      recap: recap,
      summary: '${raw['summary'] ?? ''}'.trim(),
      at: DateTime.tryParse('${raw['at']}') ?? DateTime.now(),
    );
  }
}

/// The last [kPanelRecapsKept] turns of every project, newest first.
///
/// Persisted as `~/.grid/app/panel_recaps.json`, keyed by project id. App-owned
/// and lenient like the other app stores: a missing or corrupt file reads as "no
/// history yet" rather than throwing, and an entry with no headline is dropped at
/// the parse boundary — an empty headline in a prompt is a line that costs tokens
/// and says nothing.
class PanelRecapStore {
  PanelRecapStore({File? file}) : _file = file ?? GridPaths.panelRecapsFile;

  final File _file;

  Map<String, List<PanelTurnRecord>> load() {
    try {
      if (!_file.existsSync()) return const {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return const {};
      final out = <String, List<PanelTurnRecord>>{};
      for (final entry in decoded.entries) {
        final raw = entry.value;
        if (raw is! List) continue;
        final turns = [for (final item in raw) ?PanelTurnRecord.fromJson(item)];
        if (turns.isNotEmpty) {
          out['${entry.key}'] = turns.take(kPanelRecapsKept).toList();
        }
      }
      return out;
    } on Object {
      return const {};
    }
  }

  void save(Map<String, List<PanelTurnRecord>> history) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        for (final entry in history.entries)
          if (entry.value.isNotEmpty)
            entry.key: [for (final turn in entry.value) turn.toJson()],
      }),
      flush: true,
    );
  }
}

/// The recap store, overridden in tests with a temp-file-backed one.
final panelRecapStoreProvider = Provider<PanelRecapStore>(
  (ref) => PanelRecapStore(),
);

/// Each project's recent turns: loaded once on start, written through on every
/// turn that lands, so what a project has been doing survives the app closing.
final panelRecapsProvider =
    NotifierProvider<PanelRecaps, Map<String, List<PanelTurnRecord>>>(
      PanelRecaps.new,
    );

class PanelRecaps extends Notifier<Map<String, List<PanelTurnRecord>>> {
  @override
  Map<String, List<PanelTurnRecord>> build() =>
      ref.read(panelRecapStoreProvider).load();

  /// Remember how the last turn in [projectId] came out.
  ///
  /// Called for **every** turn that ends, not only the ones a model summarised:
  /// the cheap headline is weaker signal but it is signal, and a project with no
  /// history at all is one the router can only match by name.
  void record(String projectId, {required String recap, String summary = ''}) {
    final headline = recap.trim();
    if (projectId.isEmpty || headline.isEmpty) return;
    final turn = PanelTurnRecord(
      recap: headline,
      summary: summary.trim(),
      at: DateTime.now(),
    );
    // Newest first, and the oldest falls off the end. Kept in this order because
    // that is the order the router reads them in — "most recently" is the half of
    // the signal that decides a tie.
    final next = {
      ...state,
      projectId: [turn, ...?state[projectId]?.take(kPanelRecapsKept - 1)],
    };
    state = next;
    ref.read(panelRecapStoreProvider).save(next);
  }

  /// A project's history as one block of prose for the router's prompt, or '' when
  /// it has none.
  ///
  /// Joined newest-first and separated by `;` rather than newlines: the whole
  /// candidate list is one line per project in the prompt, and a newline inside a
  /// line would make three projects look like nine.
  String recentFor(String projectId) {
    final turns = state[projectId];
    if (turns == null || turns.isEmpty) return '';
    return turns.map((t) => t.recap).join('; ');
  }
}
