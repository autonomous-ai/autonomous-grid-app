import 'saved_prompt.dart';

/// A saved prompt's name as a single slash-typeable token: whitespace collapses
/// to `-`, so `/weekly-report` stays one command instead of the menu closing at
/// the first space (see [slashQuery] — a space after `/` ends the command). Runs
/// of dashes collapse and leading/trailing ones are trimmed, so the name reads
/// the way the user types it back.
///
/// Pure so it's unit-tested and applied in one place — the library controller —
/// rather than re-derived at every call site.
String promptNameSlug(String raw) => raw
    .trim()
    .replaceAll(RegExp(r'\s+'), '-')
    .replaceAll(RegExp('-{2,}'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

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
