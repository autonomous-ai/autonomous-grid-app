/// The hosted providers, split the way the app *asks* about them.
///
/// Sharing a coding CLI you already have signed in and pasting an API key are
/// different answers to "how does this grid get a model", not two rows of one
/// dropdown — so each is its own list here, worded from what the installed CLI
/// actually offers so neither ever names a provider it can't serve.
library;

import 'api_engine_catalog.dart';

/// The providers that are a CLI already on this computer (Claude Code, Codex) —
/// no key to find and no account to hand over.
///
/// Only the ones whose binary is actually here: offering a CLI the machine
/// hasn't got is a road that ends in "not installed".
///
/// TODO(BE): no screen offers these any more — the first-run screen and the
/// Share models page both dropped their `Share <CLI>` rows on 2026-08-20, and
/// what is left reads this only to pick a default provider for a form that is
/// never handed a seat. Either the seat path comes back or it goes, form and
/// all; it should not sit here half-wired.
List<ApiEngine> seatEngines(List<ApiEngine> engines) => [
  for (final engine in engines)
    if (engine.provider.isSeat && engine.seatFound == true) engine,
];

/// The providers that want an API key pasted.
List<ApiEngine> keyEngines(List<ApiEngine> engines) => [
  for (final engine in engines)
    if (engine.provider.auth == ApiAuth.key) engine,
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
