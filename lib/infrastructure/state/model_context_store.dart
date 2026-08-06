import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// How much context each model turned out to have, in tokens, keyed by the model
/// id the app sends.
///
/// Learned, not configured: the relay carries a `context_length` for some models
/// and `null` for the rest (`TODO(BE)`), and where it says nothing the only
/// machine that knows is the one serving — which says so only when it
/// refuses a turn for being too long. Remembering that refusal is what keeps the
/// next conversation from walking into it — including after a restart, which is
/// why this is a file and not a field.
///
/// Persisted as `~/.grid/app/model_context.json`. App-owned and lenient like the
/// other app stores: a missing or corrupt file reads as "nothing learned yet"
/// rather than throwing. The file is overridable so tests point at a temp path
/// and never touch a real grid home.
class ModelContextStore {
  ModelContextStore({File? file}) : _file = file ?? GridPaths.modelContextFile;

  final File _file;

  /// What's been learned so far, or empty when nothing has (or the file is
  /// unreadable). Entries that aren't a positive token count are dropped: a
  /// hand-edited zero would read as "this model holds nothing" and stop every
  /// turn before it started.
  Map<String, int> load() {
    try {
      if (!_file.existsSync()) return const {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.value case final num tokens when tokens > 0)
            '${entry.key}': tokens.toInt(),
      };
    } on Object {
      return const {};
    }
  }

  /// Write [windows] to disk, creating the `app/` directory on first use.
  void save(Map<String, int> windows) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(windows),
      flush: true,
    );
  }
}

/// The learned-context store, overridden in tests with a temp-file-backed one.
final modelContextStoreProvider = Provider<ModelContextStore>(
  (ref) => ModelContextStore(),
);

/// The live map of learned context windows: loaded once on start, written
/// through on every lesson, so what one dead turn taught survives the app.
final learnedModelContextProvider =
    NotifierProvider<LearnedModelContext, Map<String, int>>(
      LearnedModelContext.new,
    );

class LearnedModelContext extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => ref.read(modelContextStoreProvider).load();

  /// The window [model] is now known to have. Ignored when [tokens] isn't a
  /// positive count, and when it repeats what's already known — the same wall
  /// gets hit more than once, and rewriting the file each time buys nothing.
  void learn(String model, int tokens) {
    final key = normalizeModelKey(model);
    if (key.isEmpty || tokens <= 0 || state[key] == tokens) return;
    final next = {...state, key: tokens};
    state = next;
    ref.read(modelContextStoreProvider).save(next);
  }

  /// What's known about [model], or null when it has never been refused.
  int? windowFor(String model) => state[normalizeModelKey(model)];
}

/// The form a model id is stored under: trimmed and case-folded, so the same
/// model picked twice can't land in the file as two entries.
String normalizeModelKey(String model) => model.trim().toLowerCase();
