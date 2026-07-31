import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/mcp_server.dart';
import 'package:grid_app/features/connectors/logic/connector.dart';
import 'package:grid_app/features/connectors/logic/connector_catalog.dart';
import 'package:grid_app/features/connectors/presentation/widgets/connector_list.dart';

/// The connectors grid, from the layout's side.
///
/// The card grid fixes every card's height, which buys an even wall and costs a
/// standing risk: text that doesn't fit paints outside its card and over its
/// neighbour. A widget test fails on overflow, so pumping the worst cases —
/// long blurb, long name, three columns, one column, double text size — is what
/// keeps that trade honest.
///
/// Marks are left empty on purpose. `ConnectorMark` reaches the network for a
/// real `image_url`, and a test that quietly depends on a favicon service is a
/// test that fails on a plane.
void main() {
  const longBlurb =
      'Designs, brand templates and assets in your Canva account, so the '
      'assistant can find them and make new ones, and keep the whole thing in '
      'one place rather than four.';

  ConnectorCatalogEntry entry(String code, {String description = longBlurb}) =>
      ConnectorCatalogEntry(
        id: code,
        code: code,
        label: code,
        description: description,
        mcpUrl: 'https://mcp.$code.com/mcp',
        authMethod: ConnectorAuthMethod.dcr,
        mcpReady: true,
      );

  Connector available(String code) => Connector(
    id: code,
    kind: ConnectorKind.catalog,
    name: code,
    description: longBlurb,
    status: ConnectorStatus.notConnected,
    catalogEntry: entry(code),
  );

  Connector connected(String name) => Connector(
    id: name,
    kind: ConnectorKind.customMcp,
    name: name,
    description: 'https://mcp.$name.com/mcp',
    status: ConnectorStatus.connected,
    server: McpServer(
      name: name,
      transport: McpHttp(url: 'https://mcp.$name.com/mcp'),
    ),
  );

  Future<void> pump(
    WidgetTester tester,
    List<Connector> connectors, {
    Size size = const Size(1100, 800),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: ConnectorList(connectors: connectors),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('lays available cards out side by side when there is room', (
    tester,
  ) async {
    await pump(tester, [available('canva'), available('stripe')]);
    // Same top edge means one row: the grid used the width it had.
    expect(
      tester.getTopLeft(find.text('canva')).dy,
      tester.getTopLeft(find.text('stripe')).dy,
    );
    expect(
      tester.getTopLeft(find.text('canva')).dx,
      lessThan(tester.getTopLeft(find.text('stripe')).dx),
    );
  });

  testWidgets('stacks to one column in a narrow pane', (tester) async {
    await pump(tester, [
      available('canva'),
      available('stripe'),
    ], size: const Size(360, 800));
    expect(
      tester.getTopLeft(find.text('canva')).dy,
      lessThan(tester.getTopLeft(find.text('stripe')).dy),
    );
  });

  testWidgets('shows the blurb, which is what the card exists for', (
    tester,
  ) async {
    await pump(tester, [available('canva')]);
    // Clamped to two lines by the card, so `findsOneWidget` on the full string
    // is the right assertion — the Text holds it all, the painter elides.
    expect(find.text(longBlurb), findsOneWidget);
  });

  testWidgets('a long blurb does not overflow its card', (tester) async {
    // The test fails on its own if it does: an overflowing RenderFlex throws.
    await pump(tester, [
      for (final code in ['canva', 'stripe', 'supabase', 'cloudflare'])
        available(code),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('double text size does not overflow either', (tester) async {
    // The card grows with the scaler but slower than the text does, so this is
    // exactly where the clamp has to hold.
    await pump(tester, [available('canva'), available('stripe')], textScale: 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a very long name stays on one line rather than pushing the '
      'action out of the card', (tester) async {
    await pump(tester, [
      available('a-connector-with-an-unreasonably-long-name-that-keeps-going'),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connected and available cards chapter under their headers', (
    tester,
  ) async {
    await pump(tester, [connected('my-db'), available('canva')]);
    expect(find.text('CONNECTED'), findsOneWidget);
    expect(find.text('AVAILABLE'), findsOneWidget);
    // The connected block comes first, so its header sits above the other.
    expect(
      tester.getTopLeft(find.text('CONNECTED')).dy,
      lessThan(tester.getTopLeft(find.text('AVAILABLE')).dy),
    );
  });

  testWidgets('a connected server shows its address when it has no blurb', (
    tester,
  ) async {
    await pump(tester, [connected('my-db')]);
    expect(find.textContaining('https://mcp.my-db.com/mcp'), findsWidgets);
  });
}
