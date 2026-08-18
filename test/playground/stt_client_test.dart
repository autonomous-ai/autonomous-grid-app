import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/stt_client.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';

// The exact command, `--timeout` included. The flag is not decoration: the CLI's
// own default is 30s, written for a clip of a few seconds, and a panel capture may
// be ten minutes and 19 MB. Leaving it off loses a recording somebody has already
// finished making.
const _args = [
  'stt',
  'transcribe',
  '/tmp/voice.wav',
  '--lang',
  'en',
  '--timeout',
  '120',
];

void main() {
  test(
    'returns the CLI transcript and invokes the stable STT command',
    () async {
      final cli = FakeGridCliService()
        ..stubResult(
          _args,
          const CliResult(
            exitCode: 0,
            stdout: ' turn on the lights\n',
            stderr: '',
          ),
        );

      final result = await GridCliSttClient(
        cli,
      ).transcribe(audioPath: '/tmp/voice.wav', lang: 'en');

      expect(result, isA<SttSuccess>());
      expect((result as SttSuccess).text, 'turn on the lights');
      expect(cli.runCalls, [_args]);
    },
  );

  test('maps control-plane 401 to an expired Grid session message', () async {
    final cli = FakeGridCliService()
      ..stubResult(
        _args,
        const CliResult(
          exitCode: 1,
          stdout: 'HTTP 401: {"detail":"Invalid or expired Grid session"}',
          stderr: '',
        ),
      );

    final result = await GridCliSttClient(
      cli,
    ).transcribe(audioPath: '/tmp/voice.wav', lang: 'en');

    expect(result, isA<SttFailure>());
    expect(
      (result as SttFailure).message,
      contains('Grid session has expired'),
    );
    expect(result.message, contains('grid login'));
  });

  test('a CLI that has never heard of `stt` gets one sentence, not its own '
      'usage block', () async {
    // Verbatim from a real run on 2026-08-17, where this landed whole on a
    // 466px round panel: ~380 characters, under the pass-through cap, and a
    // wall of grey text where a sentence belongs. It is also the *normal*
    // state right now — the verb is not in a CLI release yet.
    final cli = FakeGridCliService()
      ..stubResult(
        _args,
        const CliResult(
          exitCode: 2,
          stdout: '',
          stderr:
              'usage: grid [-h] [--version] [--json] <command> ...\n'
              "grid: error: argument <command>: invalid choice: 'stt' "
              '(choose from version, up, down, ls, list, info, join, leave, '
              'models, engines, device-info, catalog, pull, rm, remove, ctx, '
              'chat, image, edit, video, mode, use, login, logout, sync, '
              'members, price, router, engine, agent, launch, train)',
        ),
      );

    final result = await GridCliSttClient(
      cli,
    ).transcribe(audioPath: '/tmp/voice.wav', lang: 'en');

    expect(result, isA<SttFailure>());
    expect((result as SttFailure).message, kSttUnsupportedMessage);
    // The list of verbs is what makes it a wall; none of it reaches the screen.
    expect(result.message, isNot(contains('choose from')));
  });

  test('passes the CLI sign-in-required message through', () async {
    final cli = FakeGridCliService()
      ..stubResult(
        _args,
        const CliResult(
          exitCode: 1,
          stdout: '',
          stderr: "You're not signed in. Run `grid login` to sign in.",
        ),
      );

    final result = await GridCliSttClient(
      cli,
    ).transcribe(audioPath: '/tmp/voice.wav', lang: 'en');

    expect(result, isA<SttFailure>());
    expect(
      (result as SttFailure).message,
      "You're not signed in. Run `grid login` to sign in.",
    );
  });
}
