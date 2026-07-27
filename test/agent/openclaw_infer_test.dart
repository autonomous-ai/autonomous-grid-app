import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/openclaw_infer_service.dart';

void main() {
  group('openClawInferArgs', () {
    test('builds the one-shot infer invocation, model and --json included', () {
      // A wrong flag fails exactly like a model that wouldn't answer, so the
      // argv is pinned here rather than trusted by eye.
      expect(openClawInferArgs(prompt: 'hello', model: 'grid/qwen'), [
        'infer',
        'model',
        'run',
        '--prompt',
        'hello',
        '--model',
        'grid/qwen',
        '--json',
      ]);
    });
  });

  group('parseOpenClawReply', () {
    test('reads the reply when an output is a bare string', () {
      expect(
        parseOpenClawReply('{"ok":true,"outputs":["hi there"]}'),
        'hi there',
      );
    });

    test('reads the reply from a map output carrying the text', () {
      expect(
        parseOpenClawReply('{"ok":true,"outputs":[{"text":"answer"}]}'),
        'answer',
      );
    });

    test('joins several outputs in order', () {
      expect(
        parseOpenClawReply('{"ok":true,"outputs":["one",{"content":"two"}]}'),
        'one\ntwo',
      );
    });

    test('a failed envelope reads as no reply, not a stray line', () {
      // ok:false means the CLI is reporting an error — the caller surfaces that
      // as a failure, so parsing must not hand back a would-be answer.
      expect(
        parseOpenClawReply('{"ok":false,"error":"nope","outputs":[]}'),
        isNull,
      );
    });

    test('non-JSON, empty, or textless output is no reply', () {
      expect(parseOpenClawReply('not json at all'), isNull);
      expect(parseOpenClawReply('{"ok":true,"outputs":[]}'), isNull);
      expect(parseOpenClawReply(''), isNull);
    });
  });
}
