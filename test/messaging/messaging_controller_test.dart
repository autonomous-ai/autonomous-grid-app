import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_grid_link.dart';
import 'package:grid_app/features/agent/logic/hermes_skill_installer.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/messaging/logic/messaging_controller.dart';
import 'package:grid_app/features/messaging/logic/messaging_platform.dart';
import 'package:grid_app/features/network/logic/client_app_configurator.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/infrastructure/cli/env_file.dart';
import 'package:grid_app/infrastructure/cli/hermes_config_file.dart';
import 'package:grid_app/infrastructure/cli/hermes_gateway_service.dart';
import 'package:grid_app/infrastructure/cli/hermes_platform_policy.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _tgToken = '8123456789:AAF-abcdefghijklmnopqrstuvwxyz123';
final _telegram = MessagingPlatform.telegram;
final _grid = _network('grid-foo');

NetworkCredential _network(String id) => NetworkCredential(
  networkId: id,
  name: 'Test grid',
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok-$id',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-$id',
  deviceId: 'dev',
  roles: const ['consumer'],
  scopes: const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// A [SelectedNetwork] pinned to a fixed grid, so the controller resolves one
/// without the session/prefs wiring the real notifier reads from disk.
class _FixedSelectedNetwork extends SelectedNetwork {
  _FixedSelectedNetwork(this._fixed);
  final NetworkCredential? _fixed;
  @override
  NetworkCredential? build() => _fixed;
}

/// A gateway that records what it was asked to do — no `hermes` process, no real
/// `~/.hermes`. Holds an in-memory `.env` and one platform's link state.
class _FakeGateway implements HermesGatewayService {
  _FakeGateway({
    Map<String, String>? env,
    this.linkState = 'connected',
    this.linkError,
  }) : env = env ?? {};

  final Map<String, String> env;
  bool up = false;
  String linkState;
  String? linkError;
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
      (state: linkState, error: linkError);

  @override
  Future<bool> running() async => up;

  @override
  Future<void> startGateway() async {
    calls.add('start');
    up = true;
  }

  @override
  Future<void> restartGateway() async => calls.add('restart');
}

void main() {
  // Connecting writes into Hermes's own config — the read-and-answer limit and
  // the grid it answers with. Point every writer at a temp dir so no test ever
  // touches the real ~/.hermes.
  late Directory policyHome;
  setUp(() async {
    policyHome = await Directory.systemTemp.createTemp('grid_messaging_test');
  });
  tearDown(() => policyHome.delete(recursive: true));

  /// The grid the bot would answer with, and the models it serves. A null
  /// [grid] is a user who hasn't picked one; an empty [models] a grid sharing
  /// nothing yet.
  ProviderContainer container(
    _FakeGateway gateway, {
    NetworkCredential? grid,
    List<String> models = const ['maker/m1'],
  }) {
    final c = ProviderContainer(
      overrides: [
        hermesGatewayServiceProvider.overrideWithValue(gateway),
        hermesPlatformPolicyProvider.overrideWithValue(
          HermesPlatformPolicy(home: policyHome.path),
        ),
        hermesPathProvider.overrideWithValue('/bin/hermes'),
        selectedNetworkProvider.overrideWith(() => _FixedSelectedNetwork(grid)),
        if (grid != null)
          networkModelsForProvider(
            grid.networkId,
          ).overrideWith((ref) => Future.value(models)),
        hermesGridLinkProvider.overrideWith(
          (ref) => HermesGridLink(
            ref,
            config: HermesConfigFile(home: policyHome.path),
          ),
        ),
        clientAppConfiguratorProvider.overrideWithValue(
          ClientAppConfigurator(home: policyHome.path),
        ),
        hermesSkillInstallerProvider.overrideWithValue(
          HermesSkillInstaller(home: policyHome.path),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('connecting a bot', () {
    test('writes the bot, its whitelist and where a task sends its answer — '
        'then starts the thing that listens', () async {
      final gateway = _FakeGateway();
      final c = container(gateway, grid: _grid);
      await c.read(messagingProvider(_telegram).future);

      final error = await c
          .read(messagingProvider(_telegram).notifier)
          .connect(
            credentials: {_telegram.credentials.first.envKey: _tgToken},
            userId: '123456789',
          );

      expect(error, isNull);
      expect(gateway.calls, ['write', 'start']);
      expect(gateway.env['TELEGRAM_ALLOWED_USERS'], '123456789');
      // A task's result goes to the person who set it up — their own chat.
      expect(gateway.env['TELEGRAM_HOME_CHANNEL'], '123456789');

      final state = c.read(messagingProvider(_telegram)).value;
      expect((state as MessagingConnected).link, MessagingLink.answering);
    });

    test('read-and-answer is pinned before the gateway starts, so a remote '
        'message can never run a terminal', () async {
      final gateway = _FakeGateway();
      final c = container(gateway, grid: _grid);
      await c.read(messagingProvider(_telegram).future);

      await c
          .read(messagingProvider(_telegram).notifier)
          .connect(
            credentials: {_telegram.credentials.first.envKey: _tgToken},
            userId: '123456789',
          );

      expect(
        await HermesPlatformPolicy(
          home: policyHome.path,
        ).isRestricted(_telegram.key),
        isTrue,
      );
    });

    test('the assistant is pointed at the grid before the bot goes live, so a '
        'bot connected before the user ever chatted still has a model to '
        'answer with', () async {
      final gateway = _FakeGateway();
      final c = container(gateway, grid: _grid);
      await c.read(messagingProvider(_telegram).future);

      await c
          .read(messagingProvider(_telegram).notifier)
          .connect(
            credentials: {_telegram.credentials.first.envKey: _tgToken},
            userId: '123456789',
          );

      final config = HermesConfigFile(home: policyHome.path);
      expect(await config.valueAt(['model', 'default']), 'maker/m1');
      expect(
        await config.valueAt(['model', 'base_url']),
        _grid.relayBaseUrl,
        reason: 'the bot answers through the selected grid',
      );
    });

    test('no grid picked and an assistant pointed at nothing — the bot would '
        'be mute, so it is not connected', () async {
      final gateway = _FakeGateway();
      final c = container(gateway);
      await c.read(messagingProvider(_telegram).future);

      final error = await c
          .read(messagingProvider(_telegram).notifier)
          .connect(
            credentials: {_telegram.credentials.first.envKey: _tgToken},
            userId: '123456789',
          );

      expect(error, contains('Pick a grid'));
      expect(gateway.calls, isEmpty, reason: 'nothing was written or started');
    });

    test('a grid sharing no AI yet is refused with what to do about it, rather '
        'than a bot that answers nothing', () async {
      final gateway = _FakeGateway();
      final c = container(gateway, grid: _grid, models: const []);
      await c.read(messagingProvider(_telegram).future);

      final error = await c
          .read(messagingProvider(_telegram).notifier)
          .connect(
            credentials: {_telegram.credentials.first.envKey: _tgToken},
            userId: '123456789',
          );

      expect(error, contains('This computer'));
      expect(gateway.calls, isEmpty);
    });

    test('an assistant the user configured themselves is left alone — no grid '
        'picked is no reason to refuse it', () async {
      // A config that already names a model: Hermes has something to answer
      // with, whoever wrote it.
      await HermesConfigFile(home: policyHome.path).edit(
        (editor) =>
            HermesConfigFile.upsert(editor, ['model', 'default'], 'mine/own'),
      );
      final gateway = _FakeGateway();
      final c = container(gateway);
      await c.read(messagingProvider(_telegram).future);

      final error = await c
          .read(messagingProvider(_telegram).notifier)
          .connect(
            credentials: {_telegram.credentials.first.envKey: _tgToken},
            userId: '123456789',
          );

      expect(error, isNull);
      expect(gateway.calls, ['write', 'start']);
      expect(
        await HermesConfigFile(
          home: policyHome.path,
        ).valueAt(['model', 'default']),
        'mine/own',
        reason: "the user's own choice is not overwritten",
      );
    });

    test('a bot with nobody on its list is not connected at all — it would '
        'answer whoever found it', () async {
      final gateway = _FakeGateway();
      final c = container(gateway, grid: _grid);
      await c.read(messagingProvider(_telegram).future);

      final error = await c
          .read(messagingProvider(_telegram).notifier)
          .connect(
            credentials: {_telegram.credentials.first.envKey: _tgToken},
            userId: '',
          );

      expect(error, contains('answer anyone'));
      expect(gateway.calls, isEmpty, reason: 'nothing was written or started');
    });

    test('a token that is not one is caught here, not by a bot that silently '
        'never answers', () async {
      final gateway = _FakeGateway();
      final c = container(gateway, grid: _grid);
      await c.read(messagingProvider(_telegram).future);

      final error = await c
          .read(messagingProvider(_telegram).notifier)
          .connect(
            credentials: {_telegram.credentials.first.envKey: 'hello'},
            userId: '123456789',
          );

      expect(error, contains('BotFather'));
      expect(gateway.calls, isEmpty);
    });
  });

  group('every platform is the same flow with its own keys', () {
    test('Discord writes its own token and allowlist keys', () async {
      final gateway = _FakeGateway();
      final c = container(gateway, grid: _grid);
      const discord = MessagingPlatform.discord;
      await c.read(messagingProvider(discord).future);

      final error = await c
          .read(messagingProvider(discord).notifier)
          .connect(
            credentials: {
              discord.credentials.first.envKey: 'MTA1.abcdefg.h' * 5,
            },
            userId: '317361883817000000',
          );

      expect(error, isNull);
      expect(gateway.env['DISCORD_BOT_TOKEN'], isNotNull);
      expect(gateway.env['DISCORD_ALLOWED_USERS'], '317361883817000000');
      // Discord's home is a channel we don't collect — no user-id home channel.
      expect(gateway.env.containsKey('DISCORD_HOME_CHANNEL'), isFalse);
    });

    test('Slack needs both tokens — a missing app token is caught before '
        'connecting', () async {
      final gateway = _FakeGateway();
      final c = container(gateway, grid: _grid);
      const slack = MessagingPlatform.slack;
      await c.read(messagingProvider(slack).future);

      final missingApp = await c
          .read(messagingProvider(slack).notifier)
          .connect(
            credentials: {'SLACK_BOT_TOKEN': 'xoxb-123-abc'},
            userId: 'U01234ABCDE',
          );
      expect(missingApp, contains('xapp-'));
      expect(gateway.calls, isEmpty);

      final ok = await c
          .read(messagingProvider(slack).notifier)
          .connect(
            credentials: {
              'SLACK_BOT_TOKEN': 'xoxb-123-abc',
              'SLACK_APP_TOKEN': 'xapp-123-abc',
            },
            userId: 'U01234ABCDE',
          );
      expect(ok, isNull);
      expect(gateway.env['SLACK_BOT_TOKEN'], 'xoxb-123-abc');
      expect(gateway.env['SLACK_APP_TOKEN'], 'xapp-123-abc');
      expect(gateway.env['SLACK_ALLOWED_USERS'], 'U01234ABCDE');
    });
  });

  test('connected but not listening is not "answering" — the gateway is down, '
      'so the screen says so and offers to turn it on', () async {
    final gateway = _FakeGateway(
      env: {'TELEGRAM_BOT_TOKEN': _tgToken, 'TELEGRAM_ALLOWED_USERS': '1'},
    );
    final c = container(gateway, grid: _grid);

    final state = await c.read(messagingProvider(_telegram).future);
    expect((state as MessagingConnected).link, MessagingLink.notAnswering);

    await c.read(messagingProvider(_telegram).notifier).start();
    expect(
      (c.read(messagingProvider(_telegram)).value as MessagingConnected).link,
      MessagingLink.answering,
    );
  });

  test('the gateway is up but the platform itself is disconnected — the screen '
      "shows Hermes's own reason, not a false green", () async {
    final gateway = _FakeGateway(
      env: {'TELEGRAM_BOT_TOKEN': _tgToken, 'TELEGRAM_ALLOWED_USERS': '1'},
      linkState: 'fatal',
      linkError: 'another process is using the same bot token',
    )..up = true;
    final c = container(gateway, grid: _grid);

    final state = await c.read(messagingProvider(_telegram).future);
    expect((state as MessagingConnected).link, MessagingLink.notAnswering);
    expect(state.detail, contains('same bot token'));
  });

  test('disconnecting forgets the bot and restarts the gateway, so it stops '
      'answering as it', () async {
    final gateway = _FakeGateway(
      env: {'TELEGRAM_BOT_TOKEN': _tgToken, 'TELEGRAM_ALLOWED_USERS': '1'},
    );
    final c = container(gateway, grid: _grid);
    await c.read(messagingProvider(_telegram).future);

    await c.read(messagingProvider(_telegram).notifier).disconnect();

    expect(gateway.calls, ['remove', 'restart']);
    expect(gateway.env.containsKey('TELEGRAM_BOT_TOKEN'), isFalse);
    expect(
      c.read(messagingProvider(_telegram)).value,
      isA<MessagingDisconnected>(),
    );
  });

  test('no agent, no bot — and it says so instead of failing later', () async {
    final c = ProviderContainer(
      overrides: [hermesPathProvider.overrideWithValue(null)],
    );
    addTearDown(c.dispose);

    expect(c.read(hermesGatewayServiceProvider), isNull);
    expect(
      await c.read(messagingProvider(_telegram).future),
      isA<MessagingDisconnected>(),
    );
    expect(
      await c
          .read(messagingProvider(_telegram).notifier)
          .connect(
            credentials: {_telegram.credentials.first.envKey: _tgToken},
            userId: '1234567',
          ),
      contains("isn't set up"),
    );
  });

  group('the real gateway writes what Hermes reads', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('grid_gateway_test');
    });
    tearDown(() => tmp.delete(recursive: true));

    test(
      "a token lands in ~/.hermes/.env, and the user's own settings stay",
      () async {
        final env = File('${tmp.path}/.hermes/.env')
          ..createSync(recursive: true)
          ..writeAsStringSync('OPENAI_API_KEY=mine\n');
        final gateway = HermesGatewayServiceImpl('/bin/hermes', home: tmp.path);

        await gateway.writeEnv({
          'TELEGRAM_BOT_TOKEN': _tgToken,
          'TELEGRAM_ALLOWED_USERS': '123456789',
        }, addedBy: 'test');

        final vars = await EnvFile(env).read();
        expect(vars['TELEGRAM_BOT_TOKEN'], _tgToken);
        expect(vars['TELEGRAM_ALLOWED_USERS'], '123456789');
        expect(vars['OPENAI_API_KEY'], 'mine', reason: 'the grid key survives');
      },
    );

    test('removing deletes the token rather than leaving a dead one that still '
        'reads as connected', () async {
      final env = File('${tmp.path}/.hermes/.env');
      final gateway = HermesGatewayServiceImpl('/bin/hermes', home: tmp.path);
      await gateway.writeEnv({'TELEGRAM_BOT_TOKEN': _tgToken}, addedBy: 'test');

      await gateway.removeEnv({'TELEGRAM_BOT_TOKEN'});

      expect(await EnvFile(env).read(), isNot(contains('TELEGRAM_BOT_TOKEN')));
    });

    test('a gateway that never ran is not running', () async {
      expect(
        await HermesGatewayServiceImpl('/bin/hermes', home: tmp.path).running(),
        isFalse,
      );
    });

    test(
      'the live link comes from gateway_state.json, with its own reason when '
      'it is not connected',
      () async {
        final gateway = HermesGatewayServiceImpl('/bin/hermes', home: tmp.path);
        // No state file yet — reads as "no link", not a crash.
        expect((await gateway.readLink('telegram')).state, isEmpty);

        File('${tmp.path}/.hermes/gateway_state.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '{"platforms":{"telegram":{"state":"fatal",'
            '"error_message":"another process is using the same bot token"}}}',
          );

        final link = await gateway.readLink('telegram');
        expect(link.state, 'fatal');
        expect(link.error, contains('same bot token'));
      },
    );
  });

  group('parsePlatformLinkStatus', () {
    test('pulls the named platform state and reason out of the state JSON', () {
      final status = parsePlatformLinkStatus(
        '{"platforms":{"slack":{"state":"connected","error_message":null}}}',
        'slack',
      );
      expect(status.state, 'connected');
      expect(status.error, isNull);
    });

    test('a shape without the platform reads as no link, never a throw', () {
      expect(
        parsePlatformLinkStatus('{"platforms":{}}', 'telegram').state,
        isEmpty,
      );
      expect(parsePlatformLinkStatus('not json', 'telegram').state, isEmpty);
      expect(parsePlatformLinkStatus('[]', 'telegram').state, isEmpty);
    });
  });

  group('messagingLinkFrom', () {
    test(
      'a dead gateway is never "answering", whatever the state file says',
      () {
        final link = messagingLinkFrom(gatewayAlive: false, state: 'connected');
        expect(link.link, MessagingLink.notAnswering);
        expect(link.detail, contains("isn't running"));
      },
    );

    test('connected only counts when the gateway is alive', () {
      expect(
        messagingLinkFrom(gatewayAlive: true, state: 'connected').link,
        MessagingLink.answering,
      );
    });

    test('connecting and retrying read as "connecting", not a failure', () {
      expect(
        messagingLinkFrom(gatewayAlive: true, state: 'connecting').link,
        MessagingLink.connecting,
      );
      expect(
        messagingLinkFrom(gatewayAlive: true, state: 'retrying').link,
        MessagingLink.connecting,
      );
    });

    test('a failed platform surfaces the gateway reason', () {
      final link = messagingLinkFrom(
        gatewayAlive: true,
        state: 'fatal',
        error: 'another process is using the same bot token',
      );
      expect(link.link, MessagingLink.notAnswering);
      expect(link.detail, contains('same bot token'));
    });

    test('an alive gateway with no entry means the credentials have not loaded '
        '— surfaced, not shown as answering', () {
      final link = messagingLinkFrom(gatewayAlive: true, state: '');
      expect(link.link, MessagingLink.notAnswering);
      expect(link.detail, contains('credentials'));
    });
  });
}
