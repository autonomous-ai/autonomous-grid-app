import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/messaging/logic/telegram_controller.dart';
import 'package:grid_app/infrastructure/cli/env_file.dart';
import 'package:grid_app/infrastructure/cli/hermes_gateway_service.dart';

const _token = '8123456789:AAF-abcdefghijklmnopqrstuvwxyz123';

/// A gateway that records what it was asked to do — no `hermes` process, no real
/// `~/.hermes`.
class _FakeGateway implements HermesGatewayService {
  _FakeGateway({
    TelegramSetup? setup,
    this.telegramState = 'connected',
    this.telegramError,
  }) : setup = setup ?? _nothing;

  static const _nothing = (
    token: '',
    allowedUsers: <String>[],
    homeChannel: '',
  );

  TelegramSetup setup;
  bool up = false;

  /// The Telegram platform state the (running) gateway would report.
  String telegramState;
  String? telegramError;
  final calls = <String>[];

  @override
  Future<TelegramSetup> readTelegram() async => setup;

  @override
  Future<TelegramPlatformStatus> readTelegramLink() async =>
      (state: telegramState, error: telegramError);

  @override
  Future<void> connectTelegram({
    required String token,
    required List<String> allowedUsers,
    required String homeChannel,
  }) async {
    calls.add('connect');
    setup = (
      token: token,
      allowedUsers: allowedUsers,
      homeChannel: homeChannel,
    );
  }

  @override
  Future<void> disconnectTelegram() async {
    calls.add('disconnect');
    setup = (token: '', allowedUsers: <String>[], homeChannel: '');
  }

  @override
  Future<bool> running() async => up;

  @override
  Future<void> startGateway() async {
    calls.add('start');
    up = true;
  }

  @override
  Future<void> restartGateway() async {
    calls.add('restart');
  }
}

ProviderContainer _container(_FakeGateway gateway) {
  final container = ProviderContainer(
    overrides: [
      hermesGatewayServiceProvider.overrideWithValue(gateway),
      hermesPathProvider.overrideWithValue('/bin/hermes'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('connecting a bot', () {
    test('writes the bot, its whitelist and where a task sends its answer — '
        'then starts the thing that listens', () async {
      final gateway = _FakeGateway();
      final container = _container(gateway);
      await container.read(telegramProvider.future);

      final error = await container
          .read(telegramProvider.notifier)
          .connect(token: _token, userId: '123456789');

      expect(error, isNull);
      expect(gateway.calls, ['connect', 'start']);
      expect(gateway.setup.allowedUsers, ['123456789']);
      // A task's result goes to the person who set it up — their own chat.
      expect(gateway.setup.homeChannel, '123456789');

      final state = container.read(telegramProvider).value;
      expect((state as TelegramConnected).link, TelegramLink.answering);
    });

    test('a bot with nobody on its list is not connected at all — it would '
        'answer whoever found it', () async {
      final gateway = _FakeGateway();
      final container = _container(gateway);
      await container.read(telegramProvider.future);

      final error = await container
          .read(telegramProvider.notifier)
          .connect(token: _token, userId: '');

      expect(error, contains('anyone who finds it'));
      expect(gateway.calls, isEmpty, reason: 'nothing was written or started');
    });

    test('a token that is not one is caught here, not by a bot that silently '
        'never answers', () async {
      final gateway = _FakeGateway();
      final container = _container(gateway);
      await container.read(telegramProvider.future);

      final error = await container
          .read(telegramProvider.notifier)
          .connect(token: 'hello', userId: '123456789');

      expect(error, contains('BotFather'));
      expect(gateway.calls, isEmpty);
    });
  });

  test('connected but not listening is not "answering" — the gateway is down, '
      'so the screen says so and offers to turn it on', () async {
    final gateway = _FakeGateway(
      setup: (
        token: _token,
        allowedUsers: ['123456789'],
        homeChannel: '123456789',
      ),
    );
    final container = _container(gateway);

    final state = await container.read(telegramProvider.future);
    expect((state as TelegramConnected).link, TelegramLink.notAnswering);

    await container.read(telegramProvider.notifier).start();
    expect(
      (container.read(telegramProvider).value as TelegramConnected).link,
      TelegramLink.answering,
    );
  });

  test('the gateway is up but Telegram itself is disconnected — the screen '
      "shows Hermes's own reason, not a false green", () async {
    final gateway = _FakeGateway(
      setup: (token: _token, allowedUsers: ['1'], homeChannel: '1'),
      telegramState: 'fatal',
      telegramError: 'another process is using the same bot token',
    )..up = true;
    final container = _container(gateway);

    final state = await container.read(telegramProvider.future);
    expect((state as TelegramConnected).link, TelegramLink.notAnswering);
    expect(state.detail, contains('same bot token'));
  });

  test('disconnecting forgets the bot and restarts the gateway, so it stops '
      'answering as it', () async {
    final gateway = _FakeGateway(
      setup: (token: _token, allowedUsers: ['1'], homeChannel: '1'),
    );
    final container = _container(gateway);
    await container.read(telegramProvider.future);

    await container.read(telegramProvider.notifier).disconnect();

    expect(gateway.calls, ['disconnect', 'restart']);
    expect(container.read(telegramProvider).value, isA<TelegramDisconnected>());
  });

  test('no agent, no bot — and it says so instead of failing later', () async {
    final container = ProviderContainer(
      overrides: [hermesPathProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    expect(container.read(hermesGatewayServiceProvider), isNull);
    expect(
      await container.read(telegramProvider.future),
      isA<TelegramDisconnected>(),
    );
    expect(
      await container
          .read(telegramProvider.notifier)
          .connect(token: _token, userId: '1234567'),
      contains("isn't set up"),
    );
  });

  group('the real gateway writes what Hermes reads', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('grid_telegram_test');
    });
    tearDown(() => tmp.delete(recursive: true));

    test(
      'the token lands in ~/.hermes/.env, and the user\'s own settings stay',
      () async {
        final env = File('${tmp.path}/.hermes/.env')
          ..createSync(recursive: true)
          ..writeAsStringSync('OPENAI_API_KEY=mine\n');
        final gateway = HermesGatewayServiceImpl('/bin/hermes', home: tmp.path);

        await gateway.connectTelegram(
          token: _token,
          allowedUsers: ['123456789'],
          homeChannel: '123456789',
        );

        final vars = await EnvFile(env).read();
        expect(vars[kTelegramToken], _token);
        expect(vars[kTelegramAllowedUsers], '123456789');
        expect(vars['OPENAI_API_KEY'], 'mine', reason: 'the grid key survives');

        // And reading it back says exactly that.
        final setup = await gateway.readTelegram();
        expect(setup.allowedUsers, ['123456789']);
      },
    );

    test('disconnecting deletes the token rather than leaving a dead one that '
        'still reads as connected', () async {
      final env = File('${tmp.path}/.hermes/.env');
      final gateway = HermesGatewayServiceImpl('/bin/hermes', home: tmp.path);
      await gateway.connectTelegram(
        token: _token,
        allowedUsers: ['1'],
        homeChannel: '1',
      );

      await gateway.disconnectTelegram();

      expect(await EnvFile(env).read(), isNot(contains(kTelegramToken)));
      expect((await gateway.readTelegram()).token, isEmpty);
    });

    test('a bot with no whitelist is refused at the seam too, not only in the '
        'form', () async {
      final gateway = HermesGatewayServiceImpl('/bin/hermes', home: tmp.path);

      expect(
        () => gateway.connectTelegram(
          token: _token,
          allowedUsers: const [],
          homeChannel: '1',
        ),
        throwsA(isA<HermesGatewayException>()),
      );
    });

    test('a gateway that never ran is not running', () async {
      expect(
        await HermesGatewayServiceImpl('/bin/hermes', home: tmp.path).running(),
        isFalse,
      );
    });

    test('the live Telegram link comes from gateway_state.json, with its own '
        'reason when it is not connected', () async {
      final gateway = HermesGatewayServiceImpl('/bin/hermes', home: tmp.path);
      // No state file yet — reads as "no link", not a crash.
      expect((await gateway.readTelegramLink()).state, isEmpty);

      File('${tmp.path}/.hermes/gateway_state.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '{"platforms":{"telegram":{"state":"fatal",'
          '"error_message":"another process is using the same bot token"}}}',
        );

      final link = await gateway.readTelegramLink();
      expect(link.state, 'fatal');
      expect(link.error, contains('same bot token'));
    });
  });

  group('parseTelegramPlatformStatus', () {
    test('pulls the Telegram state and reason out of the gateway state JSON', () {
      final status = parseTelegramPlatformStatus(
        '{"platforms":{"telegram":{"state":"connected","error_message":null}}}',
      );
      expect(status.state, 'connected');
      expect(status.error, isNull);
    });

    test(
      'a shape without a Telegram entry reads as no link, never a throw',
      () {
        expect(parseTelegramPlatformStatus('{"platforms":{}}').state, isEmpty);
        expect(parseTelegramPlatformStatus('not json').state, isEmpty);
        expect(parseTelegramPlatformStatus('[]').state, isEmpty);
      },
    );
  });

  group('telegramLinkFrom', () {
    test(
      'a dead gateway is never "answering", whatever the state file says',
      () {
        final link = telegramLinkFrom(gatewayAlive: false, state: 'connected');
        expect(link.link, TelegramLink.notAnswering);
        expect(link.detail, contains("isn't running"));
      },
    );

    test('connected only counts when the gateway is alive', () {
      expect(
        telegramLinkFrom(gatewayAlive: true, state: 'connected').link,
        TelegramLink.answering,
      );
    });

    test('connecting and retrying read as "connecting", not a failure', () {
      expect(
        telegramLinkFrom(gatewayAlive: true, state: 'connecting').link,
        TelegramLink.connecting,
      );
      expect(
        telegramLinkFrom(gatewayAlive: true, state: 'retrying').link,
        TelegramLink.connecting,
      );
    });

    test('a failed platform surfaces the gateway reason', () {
      final link = telegramLinkFrom(
        gatewayAlive: true,
        state: 'fatal',
        error: 'another process is using the same bot token',
      );
      expect(link.link, TelegramLink.notAnswering);
      expect(link.detail, contains('same bot token'));
    });

    test('an alive gateway with no Telegram entry means the token has not '
        'loaded — surfaced, not shown as answering', () {
      final link = telegramLinkFrom(gatewayAlive: true, state: '');
      expect(link.link, TelegramLink.notAnswering);
      expect(link.detail, contains('token'));
    });
  });
}
