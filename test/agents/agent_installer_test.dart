import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_installer.dart';
import 'package:grid_app/infrastructure/cli/claude_installer.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/providers.dart';

/// Records the argv it was asked to run and answers with a canned result — no
/// process spawned.
class _FakeCli implements GridCliService {
  _FakeCli({this.exitCode = 0, this.stderr = ''});

  final int exitCode;
  final String stderr;
  final calls = <List<String>>[];

  @override
  Future<CliResult> run(List<String> args, {Duration? timeout}) async {
    calls.add(args);
    return CliResult(exitCode: exitCode, stdout: '', stderr: stderr);
  }

  @override
  Future<GridProcess> start(
    List<String> a, {
    Map<String, String>? environment,
  }) => throw UnimplementedError();

  @override
  Stream<DownloadProgress> pull(List<String> a) => throw UnimplementedError();
}

class _FakeClaude implements ClaudeInstaller {
  _FakeClaude({this.failure});
  final String? failure;
  final upgrades = <bool>[];

  @override
  Future<String?> install({required bool upgrade}) async {
    upgrades.add(upgrade);
    return failure;
  }
}

AgentInstaller _installer({GridCliService? cli, ClaudeInstaller? claude}) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      claudeInstallerProvider.overrideWithValue(claude ?? _FakeClaude()),
    ],
  );
  addTearDown(container.dispose);
  return container.read(agentInstallerProvider);
}

void main() {
  group('one router, one route per agent', () {
    test('a CLI-packaged agent goes to `grid agent install`, and Claude Code '
        'never does — the CLI would reject it at argv parsing', () async {
      final cli = _FakeCli();
      final claude = _FakeClaude();
      final installer = _installer(cli: cli, claude: claude);

      expect(await installer.install(AgentTool.hermes), isNull);
      expect(await installer.install(AgentTool.codex), isNull);
      expect(await installer.install(AgentTool.claude), isNull);

      expect(cli.calls, [
        ['agent', 'install', 'hermes'],
        ['agent', 'install', 'codex'],
      ]);
      expect(claude.upgrades, [false]);
    });

    test('upgrade forces a reinstall on both routes', () async {
      final cli = _FakeCli();
      final claude = _FakeClaude();
      final installer = _installer(cli: cli, claude: claude);

      await installer.install(AgentTool.hermes, upgrade: true);
      await installer.install(AgentTool.claude, upgrade: true);

      expect(cli.calls.single, ['agent', 'install', 'hermes', '--force']);
      expect(claude.upgrades, [true]);
    });
  });

  group('a failure comes back as a line the user can act on', () {
    test(
      "a CLI failure keeps the CLI's own last words, not an exit code",
      () async {
        final installer = _installer(
          cli: _FakeCli(
            exitCode: 1,
            stderr: 'error: could not reach github.com',
          ),
        );
        final message = await installer.install(AgentTool.codex);
        expect(message, contains('could not reach github.com'));
      },
    );

    test('a Claude Code failure keeps the installer own reason', () async {
      final installer = _installer(
        claude: _FakeClaude(failure: 'curl: (6) Could not resolve host'),
      );
      final message = await installer.install(AgentTool.claude);
      expect(message, contains('Could not resolve host'));
    });

    test('a CLI-packaged agent with no grid tool says so, rather than failing '
        'silently', () async {
      final message = await _installer(cli: null).install(AgentTool.hermes);
      expect(message, contains("grid tool isn't installed"));
    });

    test(
      'Claude Code needs no grid tool, so a missing CLI never stops it',
      () async {
        final message = await _installer(cli: null).install(AgentTool.claude);
        expect(message, isNull);
      },
    );
  });
}
