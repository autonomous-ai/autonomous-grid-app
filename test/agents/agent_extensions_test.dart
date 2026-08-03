import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/claude_extensions.dart';
import 'package:grid_app/features/agent/logic/hermes_extensions.dart';
import 'package:grid_app/features/agent/logic/hermes_mcp_config.dart';
import 'package:grid_app/infrastructure/cli/claude_plugin_service.dart';
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

/// Stands in for the `claude` binary so the plugins plane is non-null without
/// spawning anything — the tests here are about which planes exist, not about
/// what the CLI answers.
class _StubClaudePlugins implements ClaudePluginService {
  @override
  Future<String> listJson() async => '[]';

  @override
  Future<void> install(String identifier) async {}

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

    test('codex resolves to its own adapter', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final adapter = c.read(agentExtensionsProvider(AgentTool.codex));
      expect(adapter, isNotNull);
      expect(adapter!.tool, AgentTool.codex);
    });

    test('codex has skills and MCP, but no plugin manager', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final adapter = c.read(agentExtensionsProvider(AgentTool.codex))!;
      expect(adapter.skills, isNotNull);
      expect(adapter.mcp, isNotNull);
      // Not "not built yet": Codex's `[plugins.*]` table is written by the
      // ChatGPT desktop app, so there is no verb the screen's buttons could
      // call. The null plane is the honest answer.
      expect(adapter.plugins, isNull);
    });

    test('codex projects connector addresses', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final mcp = c.read(agentExtensionsProvider(AgentTool.codex))!.mcp!;
      // Non-null since D29. What it writes is an address and never a
      // credential — a REST connector goes through the app's bridge, and an MCP
      // one whose entry needs a header is skipped rather than written insecurely
      // (`CodexConnectorServers.entryFor`).
      expect(mcp.projectConnectorTokens, isNotNull);
    });

    test('claude resolves to its own adapter', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final adapter = c.read(agentExtensionsProvider(AgentTool.claude));
      expect(adapter, isNotNull);
      expect(adapter!.tool, AgentTool.claude);
    });

    test('claude has all three planes when the binary is there', () {
      final c = ProviderContainer(
        overrides: [
          claudePluginServiceProvider.overrideWithValue(_StubClaudePlugins()),
        ],
      );
      addTearDown(c.dispose);
      final adapter = c.read(agentExtensionsProvider(AgentTool.claude))!;
      expect(adapter.skills, isNotNull);
      expect(adapter.mcp, isNotNull);
      // The first adapter with nothing missing: unlike Codex, `claude plugin`
      // has a verb behind every button the screen offers.
      expect(adapter.plugins, isNotNull);
    });

    test('claude loses only its plugins plane without the binary', () {
      final c = ProviderContainer(
        overrides: [claudePluginServiceProvider.overrideWithValue(null)],
      );
      addTearDown(c.dispose);
      final adapter = c.read(agentExtensionsProvider(AgentTool.claude))!;
      // The plugin manager IS the CLI, so it goes with the binary — but skills
      // and MCP are files on disk and outlive it.
      expect(adapter.plugins, isNull);
      expect(adapter.skills, isNotNull);
      expect(adapter.mcp, isNotNull);
    });

    test('claude projects connector addresses', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final mcp = c.read(agentExtensionsProvider(AgentTool.claude))!.mcp!;
      // Non-null, and what it writes is an address rather than a credential: a
      // REST connector goes through the app's bridge, and an MCP one whose entry
      // needs a header is skipped rather than written insecurely
      // (`ClaudeConnectorServers.entryFor`).
      expect(mcp.projectConnectorTokens, isNotNull);
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

  group('detachLibrary', () {
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
          .detachLibrary();
    }

    File config() => File('${home.path}/.hermes/config.yaml');

    test('a config that never had the entry is left alone — the app does not '
        'create one just to say nothing', () async {
      await project();

      expect(config().existsSync(), isFalse);
    });

    test('takes the library entry out, and a second run has nothing left to '
        'do', () async {
      config().parent.createSync(recursive: true);
      config().writeAsStringSync(
        'skills:\n  external_dirs:\n    - ~/.grid/skills\n',
      );

      await project();
      final once = config().readAsStringSync();
      await project();

      expect(once, isNot(contains('~/.grid/skills')));
      expect(config().readAsStringSync(), once);
    });

    test('keeps entries the user set by hand', () async {
      config().parent.createSync(recursive: true);
      config().writeAsStringSync(
        'skills:\n  external_dirs:\n    - ~/work/my-skills\n'
        '    - ~/.grid/skills\n',
      );

      await project();

      final text = config().readAsStringSync();
      expect(text, contains('~/work/my-skills'));
      expect(text, isNot(contains('~/.grid/skills')));
    });

    test('tolerates the bare-string form hermes accepts', () async {
      config().parent.createSync(recursive: true);
      config().writeAsStringSync('skills:\n  external_dirs: ~/.grid/skills\n');

      await project();

      expect(config().readAsStringSync(), isNot(contains('~/.grid/skills')));
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
