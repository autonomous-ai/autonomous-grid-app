import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_extensions.dart';
import 'package:grid_app/features/plugins/logic/plugins_controller.dart';
import 'package:grid_app/infrastructure/cli/hermes_plugin_service.dart';

/// A fake plugin manager: records the writes, hands back a list the test
/// controls. No `hermes` process is spawned.
class _FakePlugins implements HermesPluginService {
  _FakePlugins({required this.json, this.failWith});

  String json;
  String? failWith;
  final calls = <String>[];

  void _maybeFail() {
    final message = failWith;
    if (message != null) throw HermesPluginException(message);
  }

  @override
  Future<String> listJson() async => json;

  @override
  Future<void> install(String identifier) async {
    calls.add('install:$identifier');
    _maybeFail();
  }

  @override
  Future<void> enable(String name) async {
    calls.add('enable:$name');
    _maybeFail();
    json = json.replaceAll('"not enabled"', '"enabled"');
  }

  @override
  Future<void> disable(String name) async {
    calls.add('disable:$name');
    _maybeFail();
  }

  @override
  Future<void> remove(String name) async {
    calls.add('remove:$name');
    _maybeFail();
  }
}

const _json = '''
[
  {"name": "browser-use", "status": "not enabled", "version": "1.0.0",
   "description": "Drive a browser", "source": "bundled"},
  {"name": "acme-tools", "status": "enabled", "version": "0.2.0",
   "description": "Someone's repo", "source": "git"}
]
''';

void main() {
  ({ProviderContainer container, _FakePlugins service}) harness({
    String json = _json,
    String? failWith,
    bool agentInstalled = true,
  }) {
    final service = _FakePlugins(json: json, failWith: failWith);
    final container = ProviderContainer(
      overrides: [
        hermesPluginServiceProvider.overrideWithValue(
          agentInstalled ? service : null,
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, service: service);
  }

  test('reads what Hermes really has, sorted, with its on/off state', () async {
    final h = harness();

    final plugins = await h.container.read(pluginsProvider.future);

    expect(plugins.map((p) => p.name).toList(), ['acme-tools', 'browser-use']);
    expect(plugins.first.enabled, isTrue);
    expect(plugins.first.bundled, isFalse);
    expect(plugins.last.enabled, isFalse);
    expect(plugins.last.bundled, isTrue);
  });

  test('turning a plugin on re-reads Hermes, so the switch reflects what '
      'really happened', () async {
    final h = harness();
    await h.container.read(pluginsProvider.future);

    final error = await h.container
        .read(pluginsProvider.notifier)
        .setEnabled('browser-use', enabled: true);

    expect(error, isNull);
    expect(h.service.calls, ['enable:browser-use']);
    final plugins = h.container.read(pluginsProvider).value!;
    expect(plugins.every((p) => p.enabled), isTrue);
  });

  test('a failed install comes back as a line to show, not a crash', () async {
    final h = harness(failWith: 'fatal: repository not found');
    await h.container.read(pluginsProvider.future);

    final error = await h.container
        .read(pluginsProvider.notifier)
        .install('nobody/nothing');

    expect(error, 'fatal: repository not found');
  });

  test(
    'with no agent installed, actions say so and the list is empty',
    () async {
      final h = harness(agentInstalled: false);

      expect(await h.container.read(pluginsProvider.future), isEmpty);
      expect(
        await h.container.read(pluginsProvider.notifier).install('a/b'),
        contains("isn't set up"),
      );
    },
  );

  group('parseHermesPlugins', () {
    test('skips a malformed entry, keeps the rest', () {
      final plugins = parseHermesPlugins(
        '["nope", {"name": "ok", "status": "enabled", "source": "git"}]',
      );
      expect(plugins.map((p) => p.name).toList(), ['ok']);
    });

    test('only the exact word "enabled" counts as on — "not enabled" must not '
        'read as enabled', () {
      final plugins = parseHermesPlugins(
        '[{"name": "p", "status": "not enabled", "source": "bundled"}]',
      );
      expect(plugins.single.enabled, isFalse);
    });
  });
}
