import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// How many finished turns are remembered per chat.
///
/// Three, and the reason is the same one the reference gives: one turn is a
/// skewed picture. A chat whose last turn happened to be "fixed a typo" reads
/// as a typo chat, and the voice router then sends the next spoken sentence
/// somewhere else. Three turns is enough to show what someone is *working on*
/// and still short enough that every chat's history fits in one prompt.
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

/// The last [kPanelRecapsKept] turns of every chat, newest first.
///
/// Persisted as `~/.grid/app/panel_recaps.json`, keyed by **chat id**. It was
/// keyed by project id until 2026-08-18, when a panel tile stopped being a
/// project and became a conversation. There is no migration and none is
/// possible: a project's history was the merge of its chats', and splitting it
/// back apart would be inventing which chat said what. Old keys match no chat,
/// so they read as "no history yet" and fall away as new turns land. App-owned
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

/// Each chat's recent turns: loaded once on start, written through on every
/// turn that lands, so what a chat has been doing survives the app closing.
final panelRecapsProvider =
    NotifierProvider<PanelRecaps, Map<String, List<PanelTurnRecord>>>(
      PanelRecaps.new,
    );

class PanelRecaps extends Notifier<Map<String, List<PanelTurnRecord>>> {
  @override
  Map<String, List<PanelTurnRecord>> build() =>
      ref.read(panelRecapStoreProvider).load();

  /// Remember how the last turn in [chatId] came out.
  ///
  /// Called for **every** turn that ends, not only the ones a model summarised:
  /// the cheap headline is weaker signal but it is signal, and a chat with no
  /// history at all is one the router can only match by name.
  void record(String chatId, {required String recap, String summary = ''}) {
    final headline = recap.trim();
    if (chatId.isEmpty || headline.isEmpty) return;
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
      chatId: [turn, ...?state[chatId]?.take(kPanelRecapsKept - 1)],
    };
    state = next;
    ref.read(panelRecapStoreProvider).save(next);
  }

  /// A chat's history as one block of prose for the router's prompt, or '' when
  /// it has none.
  ///
  /// Joined newest-first and separated by `;` rather than newlines: the whole
  /// candidate list is one line per chat in the prompt, and a newline inside a
  /// line would make three chats look like nine.
  String recentFor(String chatId) {
    final turns = state[chatId];
    if (turns == null || turns.isEmpty) return '';
    return turns.map((t) => t.recap).join('; ');
  }
}
