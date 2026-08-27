import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/model_usage.dart';
import 'package:grid_app/features/network/logic/node_display.dart';

/// The kind a grid stands up for its members never reaches their eyes.
///
/// A member holds no credential for it and never chose it, so its name is the
/// name of a supplier they have no relationship with and cannot act on. The
/// provider advertises these models bare; this covers the grids that registered
/// before that release, on the surfaces the app controls the text of.
void main() {
  group('withoutGridRunPrefix', () {
    test('takes the grid-run kind off, leaving the model whole', () {
      expect(
        withoutGridRunPrefix('openrouter:deepseek/deepseek-v4-flash-0731'),
        'deepseek/deepseek-v4-flash-0731',
      );
    });

    test('leaves a kind a person joined themselves alone', () {
      // Not a punctuation rule: `claude:` is a seat the user set up, and hiding
      // it would hide what they configured.
      expect(withoutGridRunPrefix('claude:claude-opus-5'), 'claude:claude-opus-5');
      expect(withoutGridRunPrefix('codex-cli:gpt-5.6-terra'), 'codex-cli:gpt-5.6-terra');
    });

    test('leaves an id with no kind at all alone', () {
      expect(withoutGridRunPrefix('qwen/qwen3.6-27b'), 'qwen/qwen3.6-27b');
      expect(withoutGridRunPrefix('auto'), 'auto');
      expect(withoutGridRunPrefix(':gpt-5.5'), ':gpt-5.5');
    });

    test('matches the kind however the relay cased it', () {
      expect(withoutGridRunPrefix('OPENROUTER:qwen/qwen3.8-27b'), 'qwen/qwen3.8-27b');
    });

    test('a prefix with nothing behind it comes back whole, never empty', () {
      // An empty cell where a model should be reads as a bug; the raw id at
      // least names something.
      expect(withoutGridRunPrefix('openrouter:'), 'openrouter:');
      expect(withoutGridRunPrefix('openrouter:   '), 'openrouter:');
    });

    test('the list is the one place a kind is named', () {
      expect(kGridRunKinds, {'openrouter'});
    });
  });

  group('splitModelId', () {
    test('strips before it splits, so the supplier never becomes the org', () {
      // The org is the half that repeats down the whole column — the most
      // visible place in the panel for a word nobody should be reading.
      final parts = splitModelId('openrouter:deepseek/deepseek-v4-flash-0731');
      expect(parts.org, 'deepseek/');
      expect(parts.org + parts.head + parts.tail, 'deepseek/deepseek-v4-flash-0731');
    });

    test('an ordinary maker prefix is still the org', () {
      final parts = splitModelId('qwen/qwen3.8-27b');
      expect(parts.org, 'qwen/');
      expect(parts.org + parts.head + parts.tail, 'qwen/qwen3.8-27b');
    });

    test('pins the distinguishing tail rather than the front', () {
      final parts = splitModelId('NVIDIA-Nemotron-3.5-Lightning-3B-v2');
      expect(parts.org, '');
      expect(parts.tail.isNotEmpty, isTrue);
      expect(parts.head + parts.tail, 'NVIDIA-Nemotron-3.5-Lightning-3B-v2');
    });
  });

  group('the display rule never touches matching', () {
    test('modelKey keeps the raw id, prefix and all', () {
      // Ids are compared across three sources that disagree on case; letting a
      // display rule into that comparison would make a row silently about a
      // different model.
      expect(
        modelKey('openrouter:deepseek/deepseek-v4-flash-0731'),
        'openrouter:deepseek/deepseek-v4-flash-0731',
      );
    });
  });
}
