import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/api_engine_choices.dart';
import 'package:grid_app/features/provider_node/logic/api_engine_catalog.dart';

ApiEngine _key(String kind, String label, String envVar) => ApiEngine(
  provider: ApiProvider(
    kind: kind,
    label: label,
    auth: ApiAuth.key,
    envVar: envVar,
    keyHint: 'sk-…',
  ),
  models: const [],
  lastVerified: '',
  hasStoredKey: false,
);

ApiEngine _seat(String kind, String label, {required bool found}) => ApiEngine(
  provider: ApiProvider(
    kind: kind,
    label: label,
    auth: ApiAuth.localCli,
    binary: kind,
    setupUrl: 'https://example.test/$kind',
  ),
  models: const [],
  lastVerified: '',
  hasStoredKey: false,
  seatFound: found,
);

final _claude = _seat('claude', 'Claude Code', found: true);
final _missingSeat = _seat('codex-cli', 'Codex CLI', found: false);
final _openai = _key('openai', 'OpenAI', 'OPENAI_API_KEY');
final _anthropic = _key('anthropic', 'Anthropic', 'ANTHROPIC_API_KEY');

void main() {
  group('the two hosted ways in are different answers, not one dropdown', () {
    test(
      'a CLI already on this computer is separated from a key you paste',
      () {
        final available = [_claude, _openai];
        expect(seatEngines(available).single.provider.kind, 'claude');
        expect(keyEngines(available).single.provider.kind, 'openai');
      },
    );

    test('a machine with no coding CLI offers no seat card', () {
      expect(seatEngines([_openai]), isEmpty);
    });

    test('a whitelisted seat whose CLI is missing is not offered — the card '
        'would be a road that ends in "install it first"', () {
      expect(seatEngines([_missingSeat]), isEmpty);
    });

    test('a CLI with only a seat provider offers no key card', () {
      expect(keyEngines([_claude]), isEmpty);
    });
  });

  group('each card names the providers this computer can actually serve', () {
    test('one provider reads as a line, not a paragraph', () {
      expect(apiKeyCardLine([_claude, _openai]), 'Bring your own OpenAI key');
    });

    test('several are listed with "or", so a card never over-promises the ones '
        'the CLI does not whitelist', () {
      expect(
        apiKeyCardLine([_openai, _anthropic]),
        'Bring your own OpenAI or '
        'Anthropic key',
      );
    });

    test(
      'nothing to offer yields nothing to say — the card is hidden then',
      () {
        expect(apiKeyCardLine([_claude]), isEmpty);
      },
    );
  });
}
