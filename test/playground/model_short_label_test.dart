import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

/// The two forms a model id is shown in: the readable `maker/model` a picker row
/// wears, and the bare name the transcript and the composer pill have room for.
void main() {
  group('modelDisplayLabel', () {
    test('a seat model reads as maker/model, not as the relay id', () {
      expect(modelDisplayLabel('claude:claude-opus-5'), 'claude/opus-5');
      expect(modelDisplayLabel('claude:claude-fable-5'), 'claude/fable-5');
    });

    test('keeps a name that does not repeat its maker whole', () {
      expect(
        modelDisplayLabel('codex-cli:gpt-5.6-terra'),
        'codex-cli/gpt-5.6-terra',
      );
      expect(modelDisplayLabel('openai:gpt-5.5'), 'openai/gpt-5.5');
    });

    test('a grid model, auto and the media modes pass through untouched', () {
      expect(modelDisplayLabel('qwen/qwen3.6-27b'), 'qwen/qwen3.6-27b');
      expect(modelDisplayLabel('auto'), 'auto');
      expect(modelDisplayLabel('Image generation'), 'Image generation');
    });

    test('a half id is shown as it came, never as an empty row', () {
      expect(modelDisplayLabel('claude:'), 'claude:');
      expect(modelDisplayLabel('claude:claude-'), 'claude:claude-');
      expect(modelDisplayLabel(':gpt-5.5'), ':gpt-5.5');
    });
  });

  group('modelShortLabel', () {
    test('drops the maker prefix, keeping the model name', () {
      expect(modelShortLabel('qwen/qwen3.6-27b'), 'qwen3.6-27b');
    });

    test('shortens a seat model the way its picker row does', () {
      expect(modelShortLabel('claude:claude-opus-5'), 'opus-5');
      expect(modelShortLabel('codex-cli:gpt-5.6-terra'), 'gpt-5.6-terra');
    });

    test('leaves a bare id (no prefix) as it is', () {
      expect(modelShortLabel('auto'), 'auto');
    });

    test('trims surrounding whitespace', () {
      expect(modelShortLabel('  maker/m1  '), 'm1');
    });

    test(
      'a trailing slash is not a name — the id comes back whole, not empty',
      () {
        expect(modelShortLabel('qwen/'), 'qwen/');
      },
    );

    test('keeps only the last segment when the id is deeply pathed', () {
      expect(modelShortLabel('org/team/model-x'), 'model-x');
    });
  });

  group('a grid-run kind', () {
    // The grid stands these up itself, on a credential no member holds, so the
    // kind's name is a supplier the reader has nothing to do with. The provider
    // advertises them bare now; this is what covers a grid that registered
    // before that release.
    test('loses its prefix outright rather than gaining a slash', () {
      expect(
        modelDisplayLabel('openrouter:deepseek/deepseek-v4-flash-0731'),
        'deepseek/deepseek-v4-flash-0731',
      );
      expect(modelDisplayLabel('openrouter:qwen/qwen3.8-27b'), 'qwen/qwen3.8-27b');
    });

    test('is stripped whatever case the relay lowercased it into', () {
      expect(modelDisplayLabel('OpenRouter:qwen/qwen3.8-27b'), 'qwen/qwen3.8-27b');
    });

    test('shortens to the model name alone, naming nothing else', () {
      expect(
        modelShortLabel('openrouter:deepseek/deepseek-v4-flash-0731'),
        'deepseek-v4-flash-0731',
      );
    });

    test('a kind a person joined themselves keeps its prefix', () {
      // The rule is about who chose the kind, not about the punctuation: a seat
      // the user set up is theirs to see.
      expect(modelDisplayLabel('claude:claude-opus-5'), 'claude/opus-5');
      expect(modelDisplayLabel('openai:gpt-5.5'), 'openai/gpt-5.5');
    });

    test('a prefix with nothing after it comes back whole, not empty', () {
      expect(modelDisplayLabel('openrouter:'), 'openrouter:');
    });

    test('an id that merely starts with the word is left alone', () {
      // No colon, so no kind — this is a model somebody named, not a namespace.
      expect(modelDisplayLabel('openrouter-mix/m1'), 'openrouter-mix/m1');
    });
  });
}
