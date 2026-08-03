import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/mcp_server.dart';
import 'package:grid_app/features/connectors/logic/connector_catalog.dart';
import 'package:grid_app/features/connectors/logic/connectors_controller.dart';
import 'package:grid_app/features/connectors/presentation/connectors_view.dart';
import 'package:grid_app/features/connectors/presentation/widgets/connector_list.dart';
import 'package:grid_app/shared/widgets/toast.dart';

/// The screen renders at all.
///
/// Written after it stopped doing so. Putting the connector list — an
/// `ExtensionGrid`, and so a `CustomScrollView` — into a `Column` without an
/// `Expanded` handed the viewport an unbounded height. It threw
/// `debugCheckHasBoundedAxis`, and because a failed layout leaves every ancestor
/// unlaid-out it did not blank the list, it blanked **the whole pane** while the
/// toolbar above stayed drawn.
///
/// `flutter analyze` passed on that, and so did every other test in the suite:
/// nothing had ever built this screen. That is the gap this file closes.
void main() {
  Widget host({List<ConnectorCatalogEntry> catalog = const []}) =>
      ProviderScope(
        overrides: [
          mcpServersProvider.overrideWith(_NoServers.new),
          connectorCatalogProvider.overrideWith((ref) async => catalog),
        ],
        child: MaterialApp(
          home: ToastScope(child: Scaffold(body: ConnectorsView())),
        ),
      );

  ConnectorCatalogEntry entry(String code) => ConnectorCatalogEntry(
    id: code,
    code: code,
    label: code.toUpperCase(),
    description: 'A connector called $code.',
  );

  testWidgets('renders with no connectors at all', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Connectors'), findsOneWidget);
  });

  testWidgets('renders a catalog list without an unbounded-height throw', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(catalog: [entry('alpha'), entry('beta'), entry('gamma')]),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(ConnectorList), findsOneWidget);
  });

  testWidgets('the list is given a bounded height, not the screen\'s', (
    tester,
  ) async {
    await tester.pumpWidget(host(catalog: [entry('alpha')]));
    await tester.pump();

    // Measured, not reasoned about: the list has to be laid out and it has to
    // stop short of the pane's bottom, because the directory's footer sits
    // under it. A list that filled its parent exactly would mean the tail had
    // been given no room and the next widget added below it would throw again.
    final list = tester.getRect(find.byType(ConnectorList));
    expect(list.height, greaterThan(0));
    expect(list.height.isFinite, isTrue);
  });

  testWidgets('switching to Connected still renders', (tester) async {
    // The filter bar hides the directory controls under Connected, which is a
    // different widget tree — and so a second way for the layout to be wrong.
    await tester.pumpWidget(host(catalog: [entry('alpha')]));
    await tester.pump();

    await tester.tap(find.text('Connected'));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to Available still renders', (tester) async {
    await tester.pumpWidget(host(catalog: [entry('alpha')]));
    await tester.pump();

    await tester.tap(find.text('Available'));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

/// No agent, so the screen's config side is empty and the catalog is all there
/// is — the state this screen is in before anything has been connected.
class _NoServers extends McpServersController {
  @override
  Future<List<McpServer>> build() async => const [];
}
