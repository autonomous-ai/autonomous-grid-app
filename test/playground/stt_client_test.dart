import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/stt_client.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';

const _args = ['stt', 'transcribe', '/tmp/voice.wav', '--lang', 'en'];

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
