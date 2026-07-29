import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_extensions.dart';
import 'package:grid_app/features/agent/logic/hermes_mcp_config.dart';
import 'package:grid_app/infrastructure/cli/hermes_config_file.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_extensions.dart';
import 'package:grid_app/features/agents/logic/mcp_server.dart';
import 'package:grid_app/infrastructure/cli/hermes_plugin_service.dart';

class _ThrowingPlugins implements HermesPluginService {
  @override
  Future<String> listJson() async => '[]';

  @override
  Future<void> install(String identifier) =>
      throw const HermesPluginException('install blew up');

  @override
  Future<void> enable(String name) async {}

  @override
  Future<void> disable(String name) async {}

  @override
  Future<void> remove(String name) async {}
}

void main() {
  group('agentExtensionsProvider', () {
    test('hermes resolves to the hermes adapter', () {
      final c = ProviderContainer(
        overrides: [
          hermesPluginServiceProvider.overrideWithValue(_ThrowingPlugins()),
        ],
      );
      addTearDown(c.dispose);
      final adapter = c.read(agentExtensionsProvider(AgentTool.hermes));
      expect(adapter, isNotNull);
      expect(adapter!.tool, AgentTool.hermes);
    });

    test('codex has no adapter yet', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(agentExtensionsProvider(AgentTool.codex)), isNull);
    });

    test('the selected agent defaults to hermes', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(extensionAgentProvider), AgentTool.hermes);
    });
  });

  group('HermesExtensions planes', () {
    test('plugins plane is null when the binary is missing', () {
      final c = ProviderContainer(
        overrides: [hermesPluginServiceProvider.overrideWithValue(null)],
      );
      addTearDown(c.dispose);
      final adapter = c.read(agentExtensionsProvider(AgentTool.hermes))!;
      expect(adapter.plugins, isNull);
      // Skills and MCP are file-based, so they outlive the binary.
      expect(adapter.skills, isNotNull);
      expect(adapter.mcp, isNotNull);
    });

    test("hermes's own failure surfaces as the contract's exception", () {
      final c = ProviderContainer(
        overrides: [
          hermesPluginServiceProvider.overrideWithValue(_ThrowingPlugins()),
        ],
      );
      addTearDown(c.dispose);
      final plane = c.read(agentExtensionsProvider(AgentTool.hermes))!.plugins!;
      expect(
        () => plane.install('owner/repo'),
        throwsA(
          isA<AgentExtensionException>().having(
            (e) => e.message,
            'message',
            'install blew up',
          ),
        ),
      );
    });
  });

  group('projectSharedStore', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('grid_ext_project_test');
    });
    tearDown(() => home.delete(recursive: true));

    Future<void> project() async {
      final c = ProviderContainer(
        overrides: [
          hermesConfigFileProvider.overrideWithValue(
            HermesConfigFile(home: home.path),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c
          .read(agentExtensionsProvider(AgentTool.hermes))!
          .skills!
          .projectSharedStore();
    }

    File config() => File('${home.path}/.hermes/config.yaml');

    test('writes external_dirs into a config that never had one', () async {
      await project();
      expect(config().readAsStringSync(), contains('~/.grid/skills'));
    });

    test('is idempotent — a second run changes nothing', () async {
      await project();
      final once = config().readAsStringSync();
      await project();
      expect(config().readAsStringSync(), once);
      // Exactly one entry, not one per run.
      expect('~/.grid/skills'.allMatches(once).length, 1);
    });

    test('keeps entries the user set by hand', () async {
      config().parent.createSync(recursive: true);
      config().writeAsStringSync(
        'skills:\n  external_dirs:\n    - ~/work/my-skills\n',
      );
      await project();
      final text = config().readAsStringSync();
      expect(text, contains('~/work/my-skills'));
      expect(text, contains('~/.grid/skills'));
    });

    test('tolerates the bare-string form hermes accepts', () async {
      config().parent.createSync(recursive: true);
      config().writeAsStringSync('skills:\n  external_dirs: ~/one-dir\n');
      await project();
      final text = config().readAsStringSync();
      expect(text, contains('~/one-dir'));
      expect(text, contains('~/.grid/skills'));
    });
  });

  group('mcp rename', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('grid_ext_rename_test');
    });
    tearDown(() => home.delete(recursive: true));

    AgentMcpPlane plane() {
      final c = ProviderContainer(
        overrides: [
          hermesMcpConfigProvider.overrideWithValue(
            HermesMcpConfig(home: home.path),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c.read(agentExtensionsProvider(AgentTool.hermes))!.mcp!;
    }

    test('drops the old key and saves the new one', () async {
      final mcp = plane();
      await mcp.upsert(
        const McpServer(
          name: 'old',
          transport: McpHttp(url: 'https://a'),
        ),
      );

      await mcp.rename(
        'old',
        const McpServer(
          name: 'new',
          transport: McpHttp(url: 'https://a'),
        ),
      );

      final servers = await mcp.read();
      expect(servers.map((s) => s.name), ['new']);
    });

    test('a rename to the same name is just a save', () async {
      final mcp = plane();
      await mcp.upsert(
        const McpServer(
          name: 'same',
          transport: McpHttp(url: 'https://a'),
        ),
      );

      await mcp.rename(
        'same',
        const McpServer(
          name: 'same',
          transport: McpHttp(url: 'https://b'),
        ),
      );

      final servers = await mcp.read();
      expect(servers.single.name, 'same');
      expect((servers.single.transport as McpHttp).url, 'https://b');
    });
  });
}
