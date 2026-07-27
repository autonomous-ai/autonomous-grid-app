import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/presentation/model_manager_dialog.dart';
import 'package:grid_app/features/models/logic/models_providers.dart';
import 'package:grid_app/features/models/logic/suggested_catalog.dart';
import 'package:grid_app/infrastructure/cli/parsers/catalog_entry.dart';
import 'package:grid_app/infrastructure/state/models/local_files.dart';
import 'package:grid_app/shared/theme/app_theme.dart';
import 'package:grid_app/shared/widgets/app_segmented.dart';

/// Pumps the dialog with the CLI-backed providers stubbed out, so the tests
/// exercise the layout rather than a machine's actual `~/.grid/models`.
Future<void> _pump(
  WidgetTester tester, {
  List<LocalModel> onDisk = const [],
  List<CatalogEntry> catalog = const [],
  SuggestOutcome suggest = const SuggestUnavailable('offline'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localModelsProvider.overrideWithValue(onDisk),
        catalogModelsProvider.overrideWith((ref) async => catalog),
        suggestedCatalogProvider.overrideWith((ref) async => suggest),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: ModelManagerDialog())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

LocalModel _model(String name, {int bytes = 5730000000}) =>
    LocalModel(name: name, path: '/tmp/models/$name', sizeBytes: bytes);

void main() {
  group('header', () {
    // The old subtitle read "1 of 1 ready to use" — a ratio that is always n of
    // n once everything suggested is downloaded, and which never mentions disk.
    testWidgets('reports disk used, not a ready-count ratio', (tester) async {
      await _pump(tester, onDisk: [_model('qwen.gguf')]);
      expect(find.text('5.7 GB used by 1 model'), findsOneWidget);
      expect(find.textContaining('ready to use'), findsNothing);
    });

    testWidgets('pluralises the model count', (tester) async {
      await _pump(
        tester,
        onDisk: [
          _model('a.gguf', bytes: 1000000000),
          _model('b.gguf', bytes: 2000000000),
        ],
      );
      expect(find.text('3.0 GB used by 2 models'), findsOneWidget);
    });

    testWidgets('says nothing is downloaded when the shelf is empty', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('Nothing downloaded yet.'), findsOneWidget);
    });
  });

  group('tabs', () {
    testWidgets('opens on Installed', (tester) async {
      await _pump(tester, onDisk: [_model('qwen.gguf')]);
      expect(find.text('Models are stored in ~/.grid/models'), findsOneWidget);
    });

    testWidgets('switching to Discover swaps the list and the footer', (
      tester,
    ) async {
      await _pump(tester, onDisk: [_model('qwen.gguf')]);
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();

      expect(find.text('Models ranked for this computer.'), findsOneWidget);
      expect(find.text('Browse models'), findsOneWidget);
      expect(find.text('Models are stored in ~/.grid/models'), findsNothing);
    });

    // A filename typed under Installed must not follow the user to Discover,
    // where it would filter the catalog to nothing and look like a failure.
    testWidgets('each tab keeps its own query', (tester) async {
      await _pump(tester, onDisk: [_model('qwen.gguf')]);
      await tester.enterText(find.byType(TextField), 'qwen');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );

      await tester.tap(find.text('Installed'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'qwen',
      );
    });

    testWidgets('the count chip hides at zero rather than showing 0', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('0'), findsNothing);
    });
  });

  group('geometry', () {
    // The old dialog set maxHeight: 720 and left the middle empty whenever the
    // content came up short. Measured, not reasoned about, per the design doc.
    //
    // Measure the panel, not `ModelManagerDialog`: Material's `Dialog` fills the
    // screen and centres its child inside, so the outer widget's rect is the
    // window's and says nothing about the panel. Probing every ancestor's rect
    // is what showed that — reading the code suggested the opposite.
    testWidgets('shrink-wraps its content instead of filling its ceiling', (
      tester,
    ) async {
      await _pump(tester, onDisk: [_model('qwen.gguf')]);
      final panel = tester.getRect(
        find
            .descendant(
              of: find.byType(ModelManagerDialog),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      // One row of content: header + controls + a tile + footer, nowhere near
      // the 540px the ceiling would allow at this window size.
      expect(panel.height, lessThan(360));
    });

    // A long list still stops at the ceiling rather than running off-screen.
    testWidgets('stops growing at the ceiling when the list is long', (
      tester,
    ) async {
      await _pump(
        tester,
        onDisk: [for (var i = 0; i < 30; i++) _model('model-$i.gguf')],
      );
      final panel = tester.getRect(
        find
            .descendant(
              of: find.byType(ModelManagerDialog),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(panel.height, lessThanOrEqualTo(600));
    });

    // The switch and the box act on the same list, so they share a row; stacked,
    // the box would read as belonging to the dialog rather than the tab.
    //
    // Both edges, not just the centres: the first version of this test compared
    // `center.dy` alone and passed while the switch stood 28px against the
    // field's 32 — centred, but 2px short at the top and bottom, which a
    // screenshot showed immediately. Two controls on one strip have to be the
    // same height, so assert the height and both edges.
    testWidgets('the segmented switch and the search box are the same size', (
      tester,
    ) async {
      await _pump(tester, onDisk: [_model('qwen.gguf')]);
      final seg = tester.getRect(find.byType(AppSegmented));
      final field = tester.getRect(find.byType(TextField));

      expect(seg.height, AppControl.height);
      expect(field.height, AppControl.height);
      expect(seg.top, moreOrLessEquals(field.top, epsilon: 0.5));
      expect(seg.bottom, moreOrLessEquals(field.bottom, epsilon: 0.5));
      expect(seg.right, lessThan(field.left));
    });

    // ...and stays that size once there's text in it. The version before this
    // measured only an empty box and passed while a pasted spec pushed the field
    // to 48px and a two-line paste to 64, against a switch fixed at 32 — a
    // growing box on a toolbar strip drags its edges off the control beside it.
    testWidgets('the search box does not grow as text is entered', (
      tester,
    ) async {
      await _pump(tester, onDisk: [_model('qwen.gguf')]);
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();

      for (final text in [
        'qwen',
        // One long line: wide enough to wrap, which is what grew the box to 48.
        'owner/repo:model-00001-of-00002.gguf',
        // The name from the report that spilled out of the capsule — long
        // enough to lay out over five wrapped lines at this field's width.
        'LuffyTheFox/Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V5-GGUF.gguf',
        // A split paste: two real lines, which grew it to 64.
        'owner/repo:model-00001-of-00002.gguf\n'
            'owner/repo:model-00002-of-00002.gguf',
      ]) {
        tester.widget<TextField>(find.byType(TextField)).controller!.value =
            TextEditingValue(text: text);
        await tester.pumpAndSettle();

        final seg = tester.getRect(find.byType(AppSegmented));
        final field = tester.getRect(find.byType(TextField));
        expect(
          field.height,
          AppControl.height,
          reason: 'field grew for: $text',
        );
        expect(seg.top, moreOrLessEquals(field.top, epsilon: 0.5));
        expect(seg.bottom, moreOrLessEquals(field.bottom, epsilon: 0.5));

        // The box staying 32px is not enough: the previous bug was the *text*
        // wrapping to five lines and spilling out of a capsule that itself
        // never moved. Assert the glyphs fit inside it.
        final editable = tester.getRect(find.byType(EditableText));
        expect(
          editable.height,
          lessThanOrEqualTo(AppControl.height),
          reason: 'text overflowed the capsule for: $text',
        );
      }
    });
  });

  group('installed list', () {
    testWidgets('a query that matches nothing offers a way to clear it', (
      tester,
    ) async {
      await _pump(tester, onDisk: [_model('qwen.gguf')]);
      await tester.enterText(find.byType(TextField), 'mistral');
      await tester.pumpAndSettle();

      expect(find.text('No match'), findsOneWidget);
      await tester.tap(find.text('Clear filter'));
      await tester.pumpAndSettle();
      expect(find.text('No match'), findsNothing);
    });

    // An empty shelf and a query that matched nothing are different situations
    // with different ways out — only one of them is worth a trip to Discover.
    testWidgets('an empty shelf sends the user to Discover', (tester) async {
      await _pump(tester);
      expect(find.text('No models yet'), findsOneWidget);

      await tester.tap(find.text('Find a model'));
      await tester.pumpAndSettle();
      expect(find.text('Models ranked for this computer.'), findsOneWidget);
    });
  });

  group('discover', () {
    // The catalog being unreachable used to print one sentence with nothing to
    // press — the only way to retry was to close the dialog and reopen it.
    testWidgets('an unreachable catalog offers Retry', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't reach the model catalog"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    // The bug this pins: `grid catalog` answers with one model, the user has
    // already downloaded it, so the not-yet-downloaded list is empty — and the
    // dialog claimed the catalog was unreachable while it was working fine.
    // "Empty because it's all filtered out" is not "empty because it broke".
    testWidgets('a catalog whose models are all downloaded is not an error', (
      tester,
    ) async {
      await _pump(
        tester,
        onDisk: [_model('qwen36.gguf')],
        catalog: const [
          CatalogEntry(
            label: 'qwen36-35b-a3b-mtp',
            hfRepo: 'unsloth/Qwen3.6-35B-A3B-MTP-GGUF',
            quantizedFile: 'qwen36.gguf',
            target: 'Apple Silicon',
            minVramGb: 32,
            kind: 'language',
          ),
        ],
      );
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't reach the model catalog"), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(
        find.text("You've already got everything suggested"),
        findsOneWidget,
      );
    });

    // The paste box used to be a fold-out tile under the list. Typing a spec in
    // the search box now surfaces the download directly.
    testWidgets('a pasted spec turns into a Download row', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField),
        'unsloth/Qwen3.6-GGUF:Qwen3.6-UD-IQ3_S.gguf',
      );
      await tester.pumpAndSettle();

      expect(find.text('Download this model'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
    });

    // Pasted through the controller, not `enterText`: the field is `maxLines: 1`
    // (it has to be — soft wrap spilled a long repo name out of the 32px
    // capsule), and that strips newlines from *typing*. A real paste sets the
    // value wholesale and keeps them, which is what this exercises.
    testWidgets('a multi-line paste counts the parts', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      field.controller!.value = const TextEditingValue(
        text:
            'owner/repo:m-00001-of-00002.gguf\n'
            'owner/repo:m-00002-of-00002.gguf',
      );
      await tester.pumpAndSettle();

      expect(find.text('Download 2 parts'), findsOneWidget);
    });

    // An ordinary word is a search, not a download.
    testWidgets('a search word does not offer a download', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'qwen');
      await tester.pumpAndSettle();

      expect(find.text('Download this model'), findsNothing);
    });
  });
}
