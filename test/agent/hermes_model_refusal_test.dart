import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_grid_link.dart';

/// Pointing Hermes at a Codex model wrote `provider: grid`, which the installed
/// Hermes rejects ("Unknown provider 'grid'") — killing every turn, chat and
/// cron. These pin that such a model is refused before any config is written,
/// with a line the user can act on and none of the raw config jargon in it.
void main() {
  group('hermesModelRefusal', () {
    test('a Codex model is refused with a next step, not config jargon', () {
      final refusal = hermesModelRefusal('codex:gpt-5.5');

      expect(refusal, kHermesCannotServeCodexModel);
      // None of the plumbing that caused the crash leaks to the user.
      expect(refusal!.toLowerCase(), isNot(contains('provider')));
      expect(refusal.toLowerCase(), isNot(contains('grid')));
      expect(refusal.toLowerCase(), contains('codex'));
      expect(refusal.toLowerCase(), contains('pick a different model'));
    });

    test('an ordinary chat-completions model is served, so it is not refused', () {
      expect(hermesModelRefusal('qwen3'), isNull);
      expect(hermesModelRefusal('llama3.1:8b'), isNull);
      expect(hermesModelRefusal('auto'), isNull);
      expect(hermesModelRefusal(''), isNull);
    });

    test('a union that includes a Codex model is refused — Hermes still could '
        'not serve the Codex part', () {
      expect(hermesModelRefusal('qwen3, codex:gpt-5.5'), isNotNull);
    });
  });
}
