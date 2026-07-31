import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/chat/presentation/grid_model_picker.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _network(String id, String name) => NetworkCredential(
  networkId: id,
  name: name,
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

void _noop(NetworkCredential _, PlaygroundModelOption _) {}

/// Mounts the pill where the composer puts it — a 140px slot at the right end of
/// a strip near the bottom of the window — and opens its menu.
Future<void> _openOver(WidgetTester tester, List<String> models) async {
  tester.view.physicalSize = const Size(1400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(
          CredentialsFile(
            networks: [_network('g', 'Serving Grid')],
            activeNetwork: 'g',
          ),
        ),
        networkModelsForProvider('g').overrideWith((ref) async => models),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 40),
              child: SizedBox(
                width: 980,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: const [
                    SizedBox(
                      width: 140,
                      child: GridModelPicker(
                        currentModelId: 'auto',
                        onSelect: _noop,
                      ),
                    ),
                    SizedBox(width: 60),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(GridModelPicker));
  await tester.pumpAndSettle();
}

/// The panel MenuAnchor actually draws, its own padding included.
Rect _panel(WidgetTester tester) =>
    tester.getRect(find.byType(FocusScope).last);

void main() {
  // The bug this file exists for: the picker used to place its menu with
  // `MenuStyle.alignment: topRight`, which puts the panel's top-*left* on the
  // pill's top-right. A 340px panel grew off to the right, the window-edge clamp
  // parked it against the screen edge, and it opened 270px clear of the pill it
  // belongs to.
  testWidgets('the menu hangs off the pill, not the window edge', (
    tester,
  ) async {
    await _openOver(tester, const ['auto', 'qwen3.6:latest']);

    final pill = tester.getRect(find.byType(GridModelPicker));
    final panel = _panel(tester);

    // Right edges flush: the panel is wider than the pill, so it grows leftward.
    expect(panel.right, pill.right);
    // And it stops well clear of the window it's in — the old placement pinned
    // this to the 1400px edge.
    expect(panel.right, lessThan(1400));
    // Opens upward, above the pill, with the gap the other menus use.
    expect(panel.bottom, lessThan(pill.top));
    expect(pill.top - panel.bottom, closeTo(6, 0.5));
  });
}
