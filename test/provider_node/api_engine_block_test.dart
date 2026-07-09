import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/api_engine_catalog.dart';
import 'package:grid_app/features/provider_node/presentation/api_engine_block.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _models = [
  ApiEngineModel(
    advertised: 'openai:gpt-5.5',
    vendorName: 'gpt-5.5',
    contextWindow: 1050000,
    supportsTools: true,
    supportsVision: true,
    notes: 'Flagship.',
  ),
  ApiEngineModel(
    advertised: 'openai:gpt-5.4-nano',
    vendorName: 'gpt-5.4-nano',
    contextWindow: 400000,
    supportsTools: true,
    supportsVision: false,
    notes: 'Cheapest.',
  ),
];

final _engine = ApiEngine(
  provider: kApiProviders.first,
  models: _models,
  lastVerified: '2026-07-08',
  hasStoredKey: false,
);

final _network = NetworkCredential.fromToml(const {
  'network_id': 'net',
  'lan_signaling_url': 'http://x',
  'access_token': 'tok',
});

Future<void> _pumpBlock(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiEnginesProvider.overrideWith((ref) async => [_engine])],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ApiEngineBlock(network: _network)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the block with all models selected by default',
      (tester) async {
    await _pumpBlock(tester);

    expect(find.text('Cloud AI'), findsOneWidget);
    expect(find.text('Models to share'), findsOneWidget);
    expect(find.text('All models (2)'), findsOneWidget);
    // Freshness note surfaces the CLI's verified date.
    expect(find.textContaining('8 Jul 2026'), findsOneWidget);
  });

  testWidgets('the model menu stays open and the summary tracks the selection',
      (tester) async {
    await _pumpBlock(tester);

    // Open the dropdown and untick one model.
    await tester.tap(find.text('All models (2)'));
    await tester.pumpAndSettle();
    expect(find.text('gpt-5.5'), findsOneWidget); // a menu row is showing

    await tester.tap(find.text('gpt-5.5'));
    await tester.pumpAndSettle();

    // closeOnActivate:false keeps the menu open, and the field summary narrows.
    expect(find.text('gpt-5.4-nano'), findsOneWidget); // still open
    expect(find.text('1 of 2 models'), findsOneWidget);
  });

  testWidgets('the open menu rows span the full field width', (tester) async {
    await _pumpBlock(tester);
    await tester.tap(find.text('All models (2)'));
    await tester.pumpAndSettle();

    // The anchor's own box is the field; each menu row must match its width
    // (not shrink-wrap to the model text).
    final fieldWidth = tester.getSize(find.byType(MenuAnchor)).width;
    final rowWidth = tester.getSize(find.byType(MenuItemButton).first).width;
    expect(rowWidth, closeTo(fieldWidth, 1));
  });

  testWidgets('the key field and model dropdown share the same height',
      (tester) async {
    await _pumpBlock(tester);
    final keyFieldHeight = tester.getSize(find.byType(TextField)).height;
    final modelFieldHeight = tester.getSize(find.byType(MenuAnchor)).height;
    expect(modelFieldHeight, keyFieldHeight);
  });
}
