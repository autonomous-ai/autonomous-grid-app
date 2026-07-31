import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_installer.dart';
import 'package:grid_app/infrastructure/cli/agent_spec_installer.dart';
import 'package:grid_app/infrastructure/cli/claude_installer.dart';

/// Records the recipes it was asked to run and answers with a canned outcome —
/// nothing is downloaded and no process is spawned.
class _FakeSpecInstaller implements AgentSpecInstaller {
  _FakeSpecInstaller({this.failure, this.chatter = const []});

  /// What the run throws, or null when it succeeds.
  final AgentInstallException? failure;

  /// Lines the installer "prints" before finishing.
  final List<String> chatter;

  final ran = <AgentInstallSpec>[];

  @override
  Future<void> run(
    AgentInstallSpec spec, {
    void Function(String line)? onLog,
  }) async {
    ran.add(spec);
    chatter.forEach(onLog ?? (_) {});
    if (failure != null) throw failure!;
  }
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

AgentInstaller _installer({
  AgentSpecInstaller? specs,
  ClaudeInstaller? claude,
}) {
  final container = ProviderContainer(
    overrides: [
      agentSpecInstallerProvider.overrideWithValue(
        specs ?? _FakeSpecInstaller(),
      ),
      claudeInstallerProvider.overrideWithValue(claude ?? _FakeClaude()),
    ],
  );
  addTearDown(container.dispose);
  return container.read(agentInstallerProvider);
}

void main() {
  group('one router, one route per agent', () {
    test('the agents the app fetches run their own recipe, and Claude Code '
        'goes to its vendor installer instead', () async {
      final specs = _FakeSpecInstaller();
      final claude = _FakeClaude();
      final installer = _installer(specs: specs, claude: claude);

      expect(await installer.install(AgentTool.hermes), isNull);
      expect(await installer.install(AgentTool.codex), isNull);
      expect(await installer.install(AgentTool.claude), isNull);

      expect(specs.ran, [
        isA<UvToolInstall>(),
        isA<GithubReleaseBinary>(),
      ], reason: 'Hermes is a Python tool, Codex a release binary');
      expect(claude.upgrades, [false]);
    });

    test("Hermes installs with the extras it's mute without — the same "
        'requirement the ACP self-repair asks for', () {
      final spec = AgentTool.hermes.installSpec;

      expect((spec as UvToolInstall).package, contains('[acp,mcp]'));
    });

    test('an update runs the same recipe — each one installs over what is '
        'there, so there is no second, weaker path to keep working', () async {
      final specs = _FakeSpecInstaller();
      final claude = _FakeClaude();
      final installer = _installer(specs: specs, claude: claude);

      await installer.install(AgentTool.hermes, upgrade: true);
      await installer.install(AgentTool.claude, upgrade: true);

      expect(specs.ran.single, isA<UvToolInstall>());
      // The vendor's installer does need telling — its script has an upgrade
      // mode of its own.
      expect(claude.upgrades, [true]);
    });

    test("the installer's output reaches the caller as it happens, so a "
        'multi-minute download can show life', () async {
      final lines = <String>[];
      final installer = _installer(
        specs: _FakeSpecInstaller(chatter: ['Downloading uv …', 'Installed.']),
      );

      await installer.install(AgentTool.hermes, onLog: lines.add);

      expect(lines, ['Downloading uv …', 'Installed.']);
    });
  });

  group('a failure comes back as a line the user can act on', () {
    test("a failed install keeps the installer's own last words, not an exit "
        'code', () async {
      final installer = _installer(
        specs: _FakeSpecInstaller(
          failure: const AgentInstallException(
            'SHA-256 mismatch for codex.tar.gz',
          ),
        ),
      );

      final message = await installer.install(AgentTool.codex);

      expect(message, contains('SHA-256 mismatch'));
    });

    test('a download that never started invites a retry instead of quoting a '
        'spawn error at the user', () async {
      final installer = _installer(
        specs: _FakeSpecInstaller(
          failure: const AgentInstallException(
            "Couldn't start uv: no such file",
            retryable: true,
          ),
        ),
      );

      final message = await installer.install(AgentTool.hermes);

      expect(message, contains('try again'));
      expect(message, isNot(contains('no such file')));
    });

    test('a Claude Code failure keeps the installer own reason', () async {
      final installer = _installer(
        claude: _FakeClaude(failure: 'curl: (6) Could not resolve host'),
      );
      final message = await installer.install(AgentTool.claude);
      expect(message, contains('Could not resolve host'));
    });
  });
}
