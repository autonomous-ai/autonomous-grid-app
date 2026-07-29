import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'prompt_library_store.dart';
import 'prompt_slash.dart';
import 'saved_prompt.dart';

/// The prompt-library store, overridden in tests with a temp-file-backed one.
final promptLibraryStoreProvider = Provider<PromptLibraryStore>(
  (ref) => PromptLibraryStore(),
);

/// The user's saved prompts, loaded once on start and persisted on every change
/// so the library survives a restart.
///
/// Exposed as an unmodifiable list — callers add/edit/remove through the
/// notifier, never by mutating the state in place.
final promptLibraryProvider =
    NotifierProvider<PromptLibraryController, List<SavedPrompt>>(
      PromptLibraryController.new,
    );

class PromptLibraryController extends Notifier<List<SavedPrompt>> {
  @override
  List<SavedPrompt> build() => List.unmodifiable([
    // Slug the names on the way in, so a library saved before this rule — the
    // user's `tank 1990` — reads as the typeable `tank-1990` right away, not
    // only after they reopen and re-save it.
    for (final prompt in ref.read(promptLibraryStoreProvider).load())
      prompt.copyWith(name: promptNameSlug(prompt.name)),
  ]);

  /// Save a new prompt and return it, so callers can act on the created entry.
  /// The name is slugged so it stays one `/`-command (see [promptNameSlug]) and
  /// the body trimmed; a blank name is rejected by the dialog before it gets
  /// here.
  SavedPrompt add({required String name, required String body}) {
    final prompt = SavedPrompt(
      id: _newId(),
      name: promptNameSlug(name),
      body: body.trim(),
    );
    _commit([...state, prompt]);
    return prompt;
  }

  /// Rewrite the prompt with [id]; a no-op when nothing matches.
  void edit({required String id, required String name, required String body}) {
    _commit([
      for (final prompt in state)
        if (prompt.id == id)
          prompt.copyWith(name: promptNameSlug(name), body: body.trim())
        else
          prompt,
    ]);
  }

  /// Drop the prompt with [id].
  void remove(String id) => _commit([
    for (final prompt in state)
      if (prompt.id != id) prompt,
  ]);

  void _commit(List<SavedPrompt> next) {
    ref.read(promptLibraryStoreProvider).save(next);
    state = List.unmodifiable(next);
  }

  /// A collision-resistant local id — the wall clock plus this session's counter,
  /// so two prompts saved in the same microsecond still differ. Ids never leave
  /// this machine, so uniqueness only has to hold locally.
  String _newId() {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return 'p_${stamp.toRadixString(36)}_${_seq++}';
  }

  int _seq = 0;
}
