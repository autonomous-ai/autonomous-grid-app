/// The ways a first-run grid can get a model, split the way the choice screen
/// asks about them.
///
/// The Model Engines screen presents every hosted provider as one block with a
/// dropdown, which is right for a settings page and wrong for a first decision:
/// signing in with a ChatGPT account and pasting an API key are different
/// answers to "how does this grid get a model", not two rows of one menu. These
/// helpers split the catalog that way and word each card from what the installed
/// CLI actually offers, so the screen never names a provider it can't serve.
library;

import '../../provider_node/logic/api_engine_catalog.dart';

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
