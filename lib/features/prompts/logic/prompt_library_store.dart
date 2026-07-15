import 'dart:convert';
import 'dart:io';

import '../../../core/grid_paths.dart';
import 'saved_prompt.dart';

/// Persists the saved-prompt library as `~/.grid/app/prompts.json`.
///
/// App-owned (the CLI never reads it) and lenient like the other app stores: a
/// missing or corrupt file, or a bad row, reads as an empty list rather than
/// throwing. The file is overridable so tests point at a temp path and never
/// touch a real grid home.
class PromptLibraryStore {
  PromptLibraryStore({File? file}) : _file = file ?? GridPaths.promptsFile;

  final File _file;

  /// The saved prompts, or an empty list when nothing is stored yet (or the file
  /// is unreadable). Bad rows are skipped, not fatal.
  List<SavedPrompt> load() {
    try {
      if (!_file.existsSync()) return const [];
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! List) return const [];
      return decoded
          .map(SavedPrompt.fromJson)
          .whereType<SavedPrompt>()
          .toList();
    } on Object {
      return const [];
    }
  }

  /// Write [prompts] to disk, creating the `app/` directory on first use.
  void save(List<SavedPrompt> prompts) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(prompts.map((prompt) => prompt.toJson()).toList()),
      flush: true,
    );
  }
}
