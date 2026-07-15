import 'saved_prompt.dart';

/// The command being typed in the composer, or null when [text] isn't one.
///
/// A slash command is a single leading-`/` token with no whitespace: `/rep`
/// gives `rep`, a lone `/` gives the empty string (show everything), and plain
/// text or a `/` followed by a space (`/a b`) gives null — the user has moved on
/// to writing a real message that just happens to start with a slash.
String? slashQuery(String text) {
  if (!text.startsWith('/')) return null;
  final rest = text.substring(1);
  if (rest.contains(RegExp(r'\s'))) return null;
  return rest;
}

/// The prompts whose name matches [query] (case-insensitive substring), in the
/// order given. An empty query matches everything, so opening the menu shows the
/// whole library.
List<SavedPrompt> matchingPrompts(List<SavedPrompt> all, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return all;
  return all
      .where((prompt) => prompt.name.toLowerCase().contains(needle))
      .toList();
}
