import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

/// The label the transcript (and the composer pill) show for a model id: the
/// bare name a person recognises, not the `maker/` path an API keys on.
void main() {
  test('drops the maker prefix, keeping the model name', () {
    expect(modelShortLabel('qwen/qwen3.6-27b'), 'qwen3.6-27b');
  });

  test('leaves a bare id (no prefix) as it is', () {
    expect(modelShortLabel('auto'), 'auto');
  });

  test('trims surrounding whitespace', () {
    expect(modelShortLabel('  maker/m1  '), 'm1');
  });

  test('a trailing slash is not a name — the id comes back whole, not empty', () {
    expect(modelShortLabel('qwen/'), 'qwen/');
  });

  test('keeps only the last segment when the id is deeply pathed', () {
    expect(modelShortLabel('org/team/model-x'), 'model-x');
  });
}
