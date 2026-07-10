import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/presentation/external_server_block.dart';

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  group('ModelField', () {
    testWidgets('is a free-text field when no models are suggested', (
      tester,
    ) async {
      final model = TextEditingController();
      addTearDown(model.dispose);
      await _pump(tester, ModelField(model: model, suggestedModels: const []));

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    });

    testWidgets('is a dropdown when the framework reports models', (
      tester,
    ) async {
      final model = TextEditingController();
      addTearDown(model.dispose);
      await _pump(
        tester,
        ModelField(model: model, suggestedModels: const ['m1', 'm2']),
      );

      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('ServerForm', () {
    testWidgets('enables Start only once Base URL and Model are filled', (
      tester,
    ) async {
      final endpoint = TextEditingController();
      final model = TextEditingController();
      final advertise = TextEditingController();
      addTearDown(endpoint.dispose);
      addTearDown(model.dispose);
      addTearDown(advertise.dispose);

      await _pump(
        tester,
        ServerForm(
          endpoint: endpoint,
          model: model,
          advertise: advertise,
          suggestedModels: const [],
          onStart: () {},
        ),
      );

      FilledButton startButton() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start engine'),
      );

      // Both fields empty → the button is disabled.
      expect(startButton().onPressed, isNull);

      // Base URL alone is not enough.
      await tester.enterText(
        find.byType(TextField).at(0),
        'http://localhost:8080',
      );
      await tester.pump();
      expect(startButton().onPressed, isNull);

      // Base URL + Model → enabled.
      await tester.enterText(find.byType(TextField).at(1), 'model.gguf');
      await tester.pump();
      expect(startButton().onPressed, isNotNull);
    });
  });
}
