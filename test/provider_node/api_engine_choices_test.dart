import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/api_engine_choices.dart';
import 'package:grid_app/features/provider_node/logic/api_engine_catalog.dart';

ApiEngine _engine(String kind, String label, {String? envVar}) => ApiEngine(
  provider: ApiProvider(
    kind: kind,
    label: label,
    envVar: envVar,
    keyHint: 'sk-…',
  ),
  models: const [],
  lastVerified: '',
  hasStoredKey: false,
);

final _codex = _engine('codex', 'ChatGPT / Codex');
final _openai = _engine('openai', 'OpenAI', envVar: 'OPENAI_API_KEY');
final _anthropic = _engine(
  'anthropic',
  'Anthropic',
  envVar: 'ANTHROPIC_API_KEY',
);

void main() {
  group('the two hosted ways in are different answers, not one dropdown', () {
    test('a subscription you sign into is separated from a key you paste', () {
      final available = [_codex, _openai];
      expect(signInEngines(available).single.provider.kind, 'codex');
      expect(keyEngines(available).single.provider.kind, 'openai');
    });

    test('a CLI with no subscription provider offers no sign-in card', () {
      expect(signInEngines([_openai]), isEmpty);
    });

    test('a CLI with only a subscription provider offers no key card', () {
      expect(keyEngines([_codex]), isEmpty);
    });
  });

  group('the key card names the providers this CLI can actually serve', () {
    test('one provider reads as a line, not a paragraph', () {
      expect(apiKeyCardLine([_codex, _openai]), 'Bring your own OpenAI key');
    });

    test('several are listed with "or", so the card never over-promises the '
        'ones the CLI does not whitelist', () {
      final subtitle = apiKeyCardLine([_openai, _anthropic]);
      expect(subtitle, contains('OpenAI or Anthropic key'));
    });

    test('no key provider yields nothing to say — the card is hidden then', () {
      expect(apiKeyCardLine([_codex]), isEmpty);
    });
  });
}
