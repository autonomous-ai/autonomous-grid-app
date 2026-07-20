import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/presentation/engine_failure_card.dart';

/// The failure text we diagnose is the engine's own last log line — third-party
/// output from llama.cpp, dyld and the relay. These lock in the readings we
/// depend on, using the real strings we've seen, so a reworded pattern can't
/// silently drop a diagnosis back to the generic fallback.
void main() {
  group('diagnoseEngineFailure', () {
    test('the dyld Metal crash reads as an engine that cannot load', () {
      // The exact shape that used to render as a bare red line above the page.
      const raw =
          'Expected in: <851138D6-C406-3ABB-801A-03A5121A4D4B> '
          '/System/Library/Frameworks/Metal.framework/Versions/A/Metal';

      final diagnosis = diagnoseEngineFailure(raw);

      expect(diagnosis.title, "The local engine couldn't start on this Mac");
      // Reinstalling fetches a build matching this macOS — the plausible fix,
      // and the only failure kind where we offer that heavy action.
      expect(diagnosis.suggestsReinstall, isTrue);
    });

    test('a missing symbol is the same class of failure', () {
      final diagnosis = diagnoseEngineFailure(
        'dyld[45231]: symbol not found in flat namespace (_MTLCreateSystemDefaultDevice)',
      );

      expect(diagnosis.title, "The local engine couldn't start on this Mac");
      expect(diagnosis.suggestsReinstall, isTrue);
    });

    test('an out-of-memory failure points at size, not at reinstalling', () {
      final diagnosis = diagnoseEngineFailure(
        'ggml_metal_graph_compute: failed to allocate buffer of 24576.00 MiB',
      );

      expect(diagnosis.title, 'Not enough memory for this model');
      // Re-downloading the engine fixes nothing here, so it must not be offered.
      expect(diagnosis.suggestsReinstall, isFalse);
    });

    test('a port clash explains that retrying picks another port', () {
      final diagnosis = diagnoseEngineFailure(
        'Port 8081 already in use, aborting',
      );

      expect(diagnosis.title, 'The port the engine needs is taken');
      expect(diagnosis.suggestsReinstall, isFalse);
    });

    test('a rejected key names the provider as the one refusing it', () {
      final diagnosis = diagnoseEngineFailure(
        'openai: 401 Unauthorized — Incorrect API key provided',
      );

      expect(diagnosis.title, 'The provider rejected your key');
      expect(diagnosis.suggestsReinstall, isFalse);
    });

    test('an unreachable relay reads as a connection problem', () {
      final diagnosis = diagnoseEngineFailure(
        'failed to reach relay: connection refused',
      );

      expect(diagnosis.title, "Couldn't reach the grid");
      expect(diagnosis.suggestsReinstall, isFalse);
    });

    test('a bad model file sends the user to re-download it', () {
      final diagnosis = diagnoseEngineFailure(
        'error loading model: failed to load model from '
        'Qwen3.6-35B-A3B-UD-IQ3_S.gguf',
      );

      expect(diagnosis.title, "This model file couldn't be loaded");
      expect(diagnosis.suggestsReinstall, isFalse);
    });

    test('matching ignores case, since the wording is not ours to fix', () {
      final shouted = diagnoseEngineFailure('SYMBOL NOT FOUND');
      expect(shouted.title, "The local engine couldn't start on this Mac");
    });

    test(
      'an unrecognised failure degrades to an honest generic reading, never a '
      'guess — the raw text is always shown beneath it',
      () {
        final diagnosis = diagnoseEngineFailure(
          'engine failed to start (exit 3).',
        );

        expect(diagnosis.title, "The engine couldn't start");
        expect(diagnosis.suggestsReinstall, isFalse);
        expect(diagnosis.explanation, isNotEmpty);
      },
    );

    test('an empty message still yields a usable card rather than blanks', () {
      final diagnosis = diagnoseEngineFailure('');

      expect(diagnosis.title, isNotEmpty);
      expect(diagnosis.explanation, isNotEmpty);
    });
  });
}
