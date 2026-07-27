import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/openclaw/openclaw_error.dart';
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

  group('friendlyOpenClawError', () {
    test('an unsupported Node reads as "update Node", not the nvm hint the CLI '
        'ended on', () {
      // OpenClaw refuses to start under an old Node and prints a multi-line
      // hint; surfacing its last line put a bare `nvm alias default 24` in the
      // chat, which names neither the problem nor a step a user would take.
      const stderr =
          'openclaw: Node.js >=22.22.3 <23, >=24.15.0 <25, or >=25.9.0 is '
          'required (current: v22.17.0).\n'
          '  nvm install 24\n'
          '  nvm alias default 24\n';
      expect(friendlyOpenClawError(stderr), kOpenClawNodeUnsupported);
    });

    test('the Bun runtime is turned away the same way — the fix is a Node', () {
      const stderr =
          'openclaw: the Bun runtime is unsupported because OpenClaw requires '
          'node:sqlite.\n';
      expect(friendlyOpenClawError(stderr), kOpenClawNodeUnsupported);
    });

    test('any other failure keeps the CLI\'s first line, where it names the '
        'problem', () {
      expect(
        friendlyOpenClawError('boom: the model is not loaded\nsee --help'),
        "OpenClaw couldn't finish: boom: the model is not loaded",
      );
    });

    test('nothing on stderr falls back to a retry, not an empty colon', () {
      expect(
        friendlyOpenClawError('   \n  '),
        "OpenClaw couldn't finish. Try sending again.",
      );
    });
  });
}
