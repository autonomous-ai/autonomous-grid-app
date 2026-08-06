import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/hermes_cron_watchdog.dart';
import 'package:grid_app/infrastructure/cli/hermes_gateway_service.dart';

void main() {
  group('cronIdleLimitUpdate', () {
    test('a file with no limit gets one, so a long scheduled answer is not '
        "killed at Hermes's 10-minute default", () {
      expect(cronIdleLimitUpdate(const {}), {
        kCronIdleLimitVar: '$kCronIdleLimitSeconds',
      });
    });

    test('a limit somebody already chose is left alone, even a shorter one — '
        'the app must not rewrite a value the user typed', () {
      expect(cronIdleLimitUpdate(const {kCronIdleLimitVar: '300'}), isNull);
    });

    test('a blank assignment is filled in, because Hermes reads it as unset and '
        'falls back to its own default', () {
      expect(cronIdleLimitUpdate(const {kCronIdleLimitVar: '  '}), isNotNull);
    });
  });

  group('HermesCronWatchdog.ensureLimit', () {
    test('writes the limit and reloads the running gateway, so it applies to '
        "today's tasks rather than after the next reboot", () async {
      final gateway = _FakeGateway(up: true);

      await HermesCronWatchdog(gateway).ensureLimit();

      expect(gateway.env[kCronIdleLimitVar], '$kCronIdleLimitSeconds');
      expect(gateway.calls, ['write', 'restart']);
    });

    test('leaves a gateway that is down alone: restarting one nobody started '
        'would put a background service on this computer unasked', () async {
      final gateway = _FakeGateway();

      await HermesCronWatchdog(gateway).ensureLimit();

      expect(gateway.env[kCronIdleLimitVar], '$kCronIdleLimitSeconds');
      expect(gateway.calls, ['write']);
    });

    test('touches nothing when a limit is already set — no write, no restart '
        'that would kill whatever the gateway is running', () async {
      final gateway = _FakeGateway(
        up: true,
        env: {kCronIdleLimitVar: '1800'},
      );

      await HermesCronWatchdog(gateway).ensureLimit();

      expect(gateway.calls, isEmpty);
    });

    test('a gateway that refuses to restart is survived, because this runs on '
        'the way to something else the user asked for', () async {
      final gateway = _FakeGateway(up: true, restartFails: true);

      await HermesCronWatchdog(gateway).ensureLimit();

      expect(gateway.env[kCronIdleLimitVar], '$kCronIdleLimitSeconds');
    });
  });
}

class _FakeGateway implements HermesGatewayService {
  _FakeGateway({
    Map<String, String>? env,
    this.up = false,
    this.restartFails = false,
  }) : env = env ?? {};

  final Map<String, String> env;
  final bool up;
  final bool restartFails;
  final calls = <String>[];

  @override
  Future<Map<String, String>> readEnv() async => Map.of(env);

  @override
  Future<void> writeEnv(
    Map<String, String> values, {
    required String addedBy,
  }) async {
    calls.add('write');
    env.addAll(values);
  }

  @override
  Future<void> removeEnv(Set<String> keys) async {
    calls.add('remove');
    keys.forEach(env.remove);
  }

  @override
  Future<PlatformLinkStatus> readLink(String platformKey) async =>
      (state: '', error: null);

  @override
  Future<bool> running() async => up;

  @override
  Future<void> startGateway() async => calls.add('start');

  @override
  Future<void> restartGateway() async {
    calls.add('restart');
    if (restartFails) throw const HermesGatewayException('launchd said no');
  }
}
