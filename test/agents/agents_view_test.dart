import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/presentation/agents_view.dart';
import 'package:grid_app/infrastructure/cli/hermes_version_service.dart';

void main() {
  Widget host() => ProviderScope(
    overrides: [
      // Hermes present so the live row shows its "Answers your chats" state.
      hermesInstalledProvider.overrideWithValue(true),
      hermesVersionProvider.overrideWith((ref) async => '0.18.2'),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 900, height: 700, child: AgentsView()),
      ),
    ),
  );

  testWidgets('lists all agents with their taglines, no overflow',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(); // let the version future resolve

    for (final tool in AgentTool.values) {
      expect(find.text(tool.name), findsOneWidget);
    }
    expect(find.text('Not available yet'), findsNWidgets(2)); // Codex, OpenClaw
    expect(find.textContaining('Answers your chats'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every row is the same height — a tagline stays on one line',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    // The rows are peers, so they must rank as peers. A tagline long enough to
    // wrap makes its row a text-line taller than the rest, which reads as
    // importance the list never meant to assign — the live agent is already
    // marked by its dot and its button.
    //
    // Tolerance, not equality: the live row's status dot stands a pixel taller
    // than a badge's plain text, and that pixel is neither visible nor the thing
    // under test. A wrapped line would cost ~16.
    final heights = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .map((w) => tester.getSize(find.byWidget(w)).height);
    final spread = heights.reduce((a, b) => a > b ? a : b) -
        heights.reduce((a, b) => a < b ? a : b);
    expect(spread, lessThan(4));
  });

  testWidgets('every agent ships a mark the app can actually load',
      (tester) async {
    // A path missing from `pubspec.yaml`'s asset list, or misspelled, compiles
    // fine and throws only when a row paints. Loading each one here moves that
    // failure into CI, where adding an agent is a one-line diff and forgetting
    // the pubspec entry is the obvious way to get it wrong.
    //
    // runAsync, because decoding hands work to the engine and waits on a real
    // Future. A test body otherwise runs in fake time, where that Future has
    // nothing to advance it and the whole run hangs rather than fails.
    await tester.runAsync(() async {
      for (final tool in AgentTool.values) {
        final data = await rootBundle.load(tool.iconAsset);
        expect(
          data.lengthInBytes,
          greaterThan(0),
          reason: '${tool.id} has an empty icon at ${tool.iconAsset}',
        );
        // It must also decode: a truncated download, or an HTML error page
        // saved under a .png, passes a length check and still fails to paint.
        final image = await decodeImageFromList(data.buffer.asUint8List());
        expect(
          image.width,
          greaterThan(0),
          reason: '${tool.id} will not decode',
        );
      }
    });
  });

  testWidgets('rows are flat — no card carries a decorative gradient',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    // This is a status list, not a gallery: every row wears the same quiet
    // surface as a plugin or job row, and what marks the live agent is its lit
    // dot and its button. A gradient creeping back in means a hero treatment
    // returned and the list stopped matching its siblings.
    final gradients = find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final d = w.decoration;
      return d is BoxDecoration && d.gradient != null;
    });
    expect(gradients, findsNothing);
  });

  testWidgets('a planned agent states itself in full ink, with no controls',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    // Nothing dims a planned row: withholding the button and showing the badge
    // already say "not yet" twice, and a third pass over the whole card would
    // fade the tagline that explains what the agent is.
    expect(find.byType(Opacity), findsNothing);
    expect(find.byType(AnimatedOpacity), findsNothing);

    // Hermes is installed in this host, so the only button on screen is its
    // Update — neither planned agent offers one.
    expect(find.widgetWithText(OutlinedButton, 'Update'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Install'), findsNothing);
  });

  testWidgets('hovering the runnable agent tints it without throwing',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Hermes'))),
    );
    // Not pumpAndSettle: the live agent's status dot pulses forever, so the
    // tree never quiesces. Pump a fixed span past the 130ms hover animation.
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
    // Hermes' own row still renders after the hover animation.
    expect(find.text('Hermes'), findsOneWidget);
  });
}
