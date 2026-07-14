import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/models/logic/engine_status.dart';
import 'package:grid_app/features/models/logic/models_providers.dart';
import 'package:grid_app/features/node_setup/logic/auto_host_controller.dart';
import 'package:grid_app/features/onboarding/logic/installer_controller.dart';
import 'package:grid_app/features/onboarding/logic/installer_stage.dart';
import 'package:grid_app/features/onboarding/presentation/installer_screen.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// Holds the installer in a chosen state, so the screen can be tested without
/// driving a real install.
class _FixedInstaller extends InstallerController {
  _FixedInstaller(this.initial);
  final InstallerState initial;

  @override
  InstallerState build() => initial;

  @override
  Future<void> run() async {}
}

/// No grid selected. Pinned, because the real provider reads the developer's own
/// `~/.grid` — which would make the checklist depend on who runs the test.
class _NoNetwork extends SelectedNetwork {
  @override
  NetworkCredential? build() => null;
}

Future<void> _pump(WidgetTester tester, InstallerState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supportsBuiltInEngineProvider.overrideWithValue(true),
        gridCliServiceProvider.overrideWithValue(null),
        selectedNetworkProvider.overrideWith(_NoNetwork.new),
        engineStatusProvider.overrideWithValue(EngineStatus.notInstalled),
        localModelsProvider.overrideWithValue(const []),
        hermesPathProvider.overrideWithValue(null),
        installerControllerProvider.overrideWith(() => _FixedInstaller(state)),
      ],
      child: const MaterialApp(home: InstallerScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows every step of the job, so nothing is a surprise', (
    tester,
  ) async {
    await _pump(tester, const InstallerRunning());

    for (final stage in InstallerStage.values) {
      expect(find.text(stage.title), findsOneWidget);
    }
    expect(find.text('0 of 5 steps'), findsOneWidget);
  });

  testWidgets('while running, the only action is a way out', (tester) async {
    await _pump(tester, const InstallerRunning());

    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('a failure offers a retry and a way into the app', (
    tester,
  ) async {
    await _pump(tester, const InstallerFailed());

    expect(find.text("Setup didn't finish"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Continue without this computer'), findsOneWidget);
  });
}
