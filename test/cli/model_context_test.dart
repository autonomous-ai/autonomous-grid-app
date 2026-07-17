import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/parsers/model_context.dart';

void main() {
  test('parses the real `grid ctx --json` payload', () {
    const stdout =
        '{"file": "/Users/x/.grid/models/Qwen3.6-35B-A3B-UD-IQ3_S.gguf", '
        '"context_length": 262144}';

    final ctx = ModelContext.parse(stdout);

    expect(ctx, isNotNull);
    expect(ctx!.contextLength, 262144);
    expect(ctx.file, endsWith('Qwen3.6-35B-A3B-UD-IQ3_S.gguf'));
  });

  test('tolerates surrounding whitespace/newlines', () {
    final ctx = ModelContext.parse(
      '\n  {"file": "m.gguf", "context_length": 8192}\n',
    );
    expect(ctx?.contextLength, 8192);
  });

  test('returns null on empty, non-JSON, or malformed output', () {
    expect(ModelContext.parse(''), isNull);
    expect(ModelContext.parse('not json'), isNull);
    expect(ModelContext.parse('[1, 2, 3]'), isNull); // JSON, but not an object
  });

  test('returns null when context_length is missing or not a positive int', () {
    expect(ModelContext.parse('{"file": "m.gguf"}'), isNull);
    expect(ModelContext.parse('{"context_length": 0}'), isNull);
    expect(ModelContext.parse('{"context_length": -1}'), isNull);
    expect(ModelContext.parse('{"context_length": "262144"}'), isNull);
  });
}
