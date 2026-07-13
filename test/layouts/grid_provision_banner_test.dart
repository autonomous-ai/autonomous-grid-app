import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/create_network_controller.dart';
import 'package:grid_app/infrastructure/api/models/managed_network.dart';
import 'package:grid_app/shared/layouts/widgets/grid_provision_banner.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// Pins the banner to a fixed [CreateNetworkState] so we can assert what it says
/// per state, without wiring the HTTP/CLI stack behind a real create.
class _StubController extends CreateNetworkController {
  _StubController(this._state);
  final CreateNetworkState _state;

  @override
  CreateNetworkState build() => _state;
}

const _created = ManagedNetwork(
  networkId: 'net-1',
  name: 'Huy AI Grid',
  networkType: 'permissioned-public',
  signalingUrl: 'https://signal.example',
  port: 4433,
  status: 'active',
  plan: 'free',
);

Future<void> _pumpBanner(WidgetTester tester, CreateNetworkState state) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        createNetworkControllerProvider
            .overrideWith(() => _StubController(state)),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(body: GridProvisionBanner()),
      ),
    ),
  );
}

/// The banner's own strip — the [Material] it paints. Scoped to the banner so a
/// hidden banner reads as "nothing", rather than matching the Scaffold's own
/// Material.
final _bannerContent = find.descendant(
  of: find.byType(GridProvisionBanner),
  matching: find.byType(Material),
);

void main() {
  testWidgets('announces the grid the app provisions by itself', (tester) async {
    await _pumpBanner(tester, const CreateNetworkSubmitting(auto: true));

    expect(find.textContaining('Setting up your grid'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('stays quiet while the user creates a grid from the dialog', (
    tester,
  ) async {
    // The dialog has its own spinner in front of the user — a banner would only
    // double up.
    await _pumpBanner(tester, const CreateNetworkSubmitting());

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(_bannerContent, findsNothing);
  });

  testWidgets('surfaces a failed auto-create with a retry', (tester) async {
    await _pumpBanner(
      tester,
      const CreateNetworkFailed('The server is busy.', auto: true),
    );

    expect(find.textContaining("Couldn't set up your grid"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets('disappears once the grid is ready', (tester) async {
    await _pumpBanner(tester, const CreateNetworkDone(_created, auto: true));

    expect(_bannerContent, findsNothing);
  });
}
