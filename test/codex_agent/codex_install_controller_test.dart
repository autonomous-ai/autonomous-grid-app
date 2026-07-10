import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/codex_install_controller.dart';
import 'package:grid_app/features/codex_agent/logic/codex_providers.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/infrastructure/cli/codex_resolver.dart';
import 'package:grid_app/infrastructure/cli/host_shell_service.dart';

/// Records the commands handed to Terminal; [opens] toggles launch success.
class _FakeShell implements HostShellService {
  _FakeShell({this.opens = true});
  bool opens;
  final commands = <String>[];

  @override
  Future<bool> openTerminal(String command) async {
    commands.add(command);
    return opens;
  }
}

/// A mutable codex path so a test can flip "installed" mid-flow.
class _Lookup {
  String? path;
  String? call(String name) => name == 'codex' ? path : null;
}

ProviderContainer _container({
  required bool brew,
  required _FakeShell shell,
  required _Lookup lookup,
}) {
  final container = ProviderContainer(
    overrides: [
      homebrewInstalledProvider.overrideWithValue(brew),
      hostShellServiceProvider.overrideWithValue(shell),
      codexResolverProvider.overrideWithValue(
        CodexResolver(lookup: lookup.call),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('run without Homebrew fails with guidance', () async {
    final container = _container(
      brew: false,
      shell: _FakeShell(),
      lookup: _Lookup(),
    );
    await container.read(codexInstallControllerProvider.notifier).run();

    final state = container.read(codexInstallControllerProvider);
    expect(state, isA<CodexSetupFailed>());
    expect((state as CodexSetupFailed).message, contains('Homebrew'));
  });

  test(
    'run with Homebrew opens the cask install and awaits Continue',
    () async {
      final shell = _FakeShell();
      final container = _container(brew: true, shell: shell, lookup: _Lookup());

      await container.read(codexInstallControllerProvider.notifier).run();

      expect(
        container.read(codexInstallControllerProvider),
        isA<CodexSetupInstalling>(),
      );
      expect(shell.commands.single, 'brew install --cask codex');
    },
  );

  test('run fails when Terminal cannot be opened', () async {
    final container = _container(
      brew: true,
      shell: _FakeShell(opens: false),
      lookup: _Lookup(),
    );
    await container.read(codexInstallControllerProvider.notifier).run();

    expect(
      container.read(codexInstallControllerProvider),
      isA<CodexSetupFailed>(),
    );
  });

  test('Continue reaches Done once codex is detected', () async {
    final lookup = _Lookup();
    final container = _container(
      brew: true,
      shell: _FakeShell(),
      lookup: lookup,
    );
    final controller = container.read(codexInstallControllerProvider.notifier);

    await controller.run();
    // The install finished in Terminal: codex is now on PATH.
    lookup.path = '/opt/homebrew/bin/codex';
    controller.continueSetup();

    expect(
      container.read(codexInstallControllerProvider),
      isA<CodexSetupDone>(),
    );
  });

  test('Continue re-prompts while codex is still missing', () async {
    final container = _container(
      brew: true,
      shell: _FakeShell(),
      lookup: _Lookup(),
    );
    final controller = container.read(codexInstallControllerProvider.notifier);

    await controller.run();
    controller.continueSetup();

    final state = container.read(codexInstallControllerProvider);
    expect(state, isA<CodexSetupInstalling>());
    expect((state as CodexSetupInstalling).note, isNotNull);
  });
}
