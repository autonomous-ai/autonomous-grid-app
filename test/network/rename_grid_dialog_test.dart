import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/rename_network_controller.dart';
import 'package:grid_app/features/network/presentation/rename_grid_dialog.dart';
import 'package:grid_app/infrastructure/api/managed_network_client.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _net = 'net-1';
const _oldName = 'Old Grid';

final _network = NetworkCredential(
  networkId: _net,
  name: _oldName,
  networkType: 'permissioned-public',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-1',
  deviceId: 'dev',
  roles: const ['admin'],
  scopes: const [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// Records the names the dialog asked the control plane to save.
class _StubRename {
  final List<String> saved = [];

  Future<(bool, ManagedNetworkError?)> call({
    required String apiUrl,
    required String sessionToken,
    required String networkId,
    required String name,
  }) async {
    saved.add(name);
    return (true, null);
  }
}

/// Opens the dialog the way the header does — through [RenameGridDialog.show],
/// so the test also covers the reset it performs on the way in (doing that in a
/// widget life-cycle instead would throw "modified a provider while building").
Future<void> _pumpDialog(WidgetTester tester, _StubRename rename) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      managedNetworkRenameProvider.overrideWithValue(rename.call),
      gridCliServiceProvider.overrideWithValue(FakeGridCliService()),
      activeRemoteGridProvider.overrideWithValue(null),
      sessionProvider.overrideWithValue(
        CredentialsFile(networks: [_network], sessionToken: 'tok'),
      ),
    ],
    // A Scaffold, because the dialog confirms the rename with a snackbar.
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () => RenameGridDialog.show(context, ref, _network),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on the grid\'s current name', (tester) async {
    await _pumpDialog(tester, _StubRename());

    expect(find.widgetWithText(TextField, _oldName), findsOneWidget);
  });

  testWidgets('saves the new name and closes', (tester) async {
    final rename = _StubRename();
    await _pumpDialog(tester, rename);

    await tester.enterText(find.byType(TextField), 'New Grid');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(rename.saved, ['New Grid']);
    expect(find.byType(RenameGridDialog), findsNothing);
  });

  testWidgets('shows the failure and stays open on an invalid name',
      (tester) async {
    final rename = _StubRename();
    await _pumpDialog(tester, rename);

    await tester.enterText(find.byType(TextField), '  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(rename.saved, isEmpty, reason: 'never reaches the control plane');
    expect(find.text('Enter a name for your grid.'), findsOneWidget);
    expect(find.byType(RenameGridDialog), findsOneWidget);
  });
}
