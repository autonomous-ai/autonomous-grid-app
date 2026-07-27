import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/hermes/hermes_tool.dart';
import 'package:grid_app/features/node_setup/logic/auto_host_controller.dart';
import 'package:grid_app/features/onboarding/logic/installer_rows.dart';
import 'package:grid_app/features/onboarding/logic/installer_stage.dart';

ProviderContainer _container({bool agent = false, bool canHost = true}) {
  final container = ProviderContainer(
    overrides: [
      supportsBuiltInEngineProvider.overrideWithValue(canHost),
      hermesPathProvider.overrideWithValue(agent ? '/bin/hermes' : null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

InstallStatus _statusOf(ProviderContainer c, InstallerStage stage) => c
    .read(installerRowsProvider)
    .firstWhere((row) => row.stage == stage)
    .status;

void main() {
  group('installerNeeded — only the assistant holds the user here now', () {
    test('a brand-new computer needs the installer', () {
      expect(_container().read(installerNeededProvider), isTrue);
    });

    test('a computer with the assistant already installed does not', () {
      expect(_container(agent: true).read(installerNeededProvider), isFalse);
    });

    test('the engine is no longer a gate — running a model locally is a choice '
        'made after setup, not something the installer forces', () {
      // No engine, but the assistant is here: nothing holds the user at the
      // installer; the choose-a-model screen comes next.
      expect(_container(agent: true).read(installerNeededProvider), isFalse);
    });

    test(
      'a machine that cannot host the built-in engine still sees it when the '
      'assistant is missing — agents install on every OS, only the engine is '
      'Mac-gated',
      () {
        expect(
          _container(canHost: false).read(installerNeededProvider),
          isTrue,
        );
      },
    );

    test('a non-hosting machine with the assistant already installed does not '
        'see it', () {
      expect(
        _container(canHost: false, agent: true).read(installerNeededProvider),
        isFalse,
      );
    });
  });

  group('rows read the machine, not a flag', () {
    test('an assistant already installed shows as done, and is not redone', () {
      expect(
        _statusOf(_container(agent: true), InstallerStage.agent),
        InstallStatus.done,
      );
    });

    test('a fresh machine has the assistant step pending', () {
      expect(
        _statusOf(_container(), InstallerStage.agent),
        InstallStatus.pending,
      );
    });

    test(
      'the checklist is grid then assistant — no engine, no model, no share',
      () {
        final rows = _container().read(installerRowsProvider);

        expect(rows.map((r) => r.stage), InstallerStage.values);
        expect(InstallerStage.values, [
          InstallerStage.grid,
          InstallerStage.agent,
        ]);
      },
    );
  });
}
