/// The hosted providers, split the way the app *asks* about them.
///
/// Signing in with a ChatGPT account and pasting an API key are different
/// answers to "how does this grid get a model", not two rows of one dropdown —
/// so both the first-run screen and the Model Engines tab give them a card each,
/// worded from what the installed CLI actually offers so neither ever names a
/// provider it can't serve.
library;

import 'api_engine_catalog.dart';

/// The providers you sign into (a ChatGPT / Codex subscription) — no key to
/// find, so this is the fastest way in when it's available.
List<ApiEngine> signInEngines(List<ApiEngine> engines) => [
  for (final engine in engines)
    if (engine.provider.usesSignIn) engine,
];

/// The providers that want an API key pasted.
List<ApiEngine> keyEngines(List<ApiEngine> engines) => [
  for (final engine in engines)
    if (!engine.provider.usesSignIn) engine,
];

/// "Bring your own OpenAI key" — the API-key card's one line, naming the
/// providers this CLI can actually serve rather than a hopeful list. Empty when
/// there are none, which is also when the card isn't shown.
String apiKeyCardLine(List<ApiEngine> engines) {
  final names = [
    for (final engine in keyEngines(engines)) engine.provider.label,
  ];
  if (names.isEmpty) return '';
  return 'Bring your own ${_joined(names)} key';
}

/// `a`, `a or b`, `a, b or c` — an English list, so the subtitle reads as a
/// sentence however many providers the CLI whitelists.
String _joined(List<String> names) {
  if (names.length == 1) return names.first;
  final head = names.sublist(0, names.length - 1).join(', ');
  return '$head or ${names.last}';
}
