import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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

  testWidgets('only the runnable agent wears the hero wash', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    // The hero wash is the only thing on the screen that paints a RadialGradient
    // (its corner glow). Exactly one runnable agent → exactly one such layer, so
    // the two planned agents provably stay flat.
    final radialGlows = find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final d = w.decoration;
      return d is BoxDecoration && d.gradient is RadialGradient;
    });
    expect(radialGlows, findsOneWidget);
  });

  testWidgets('hovering the runnable agent lifts it without throwing',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('Hermes'))),
    );
    // Not pumpAndSettle: the live agent's status dot pulses forever, so the
    // tree never quiesces. Pump a fixed span past the 160ms hover animation.
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
    // Hermes' own row still renders after the hover animation.
    expect(find.text('Hermes'), findsOneWidget);
  });
}
