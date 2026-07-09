import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/node_setup/logic/node_setup_controller.dart';
import 'package:grid_app/features/node_setup/logic/node_setup_plan.dart';
import 'package:grid_app/shared/layouts/widgets/node_setup_banner.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// Pins the banner to a fixed [NodeSetupState] so we can assert how it *looks*
/// per failure kind, without wiring the whole CLI/log stack. The CLI-line →
/// [NodeSetupFailureKind] mapping is already covered by the controller test;
/// here we only verify the kind → rendering half.
class _StubController extends NodeSetupController {
  _StubController(this._state);
  final NodeSetupState _state;

  @override
  NodeSetupState build() => _state;
}

const _llamaStep = SetupStep(
  action: SetupAction.installLlama,
  title: 'Install the built-in engine',
  detail: '',
  args: ['engine', 'install', 'llama.cpp'],
  isDownload: false,
);

Future<void> _pumpBanner(WidgetTester tester, NodeSetupState state) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        nodeSetupControllerProvider.overrideWith(() => _StubController(state)),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(body: NodeSetupBanner()),
      ),
    ),
  );
}

/// The banner's own background is the outermost [Material] inside the widget —
/// depth-first, so `.first` skips the button Materials nested deeper.
Color? _bannerColor(WidgetTester tester) {
  final finder = find.descendant(
    of: find.byType(NodeSetupBanner),
    matching: find.byType(Material),
  );
  return tester.widget<Material>(finder.first).color;
}

void main() {
  final scheme = buildAppTheme().colorScheme;

  testWidgets('an unsupported stop reads as a calm notice, not an error',
      (tester) async {
    await _pumpBanner(
      tester,
      const NodeSetupFailed(
        step: _llamaStep,
        message: "This computer can't run the built-in engine yet…",
        log: [],
        kind: NodeSetupFailureKind.unsupported,
      ),
    );

    // Reassuring copy + info glyph, and none of the alarming error styling.
    expect(find.textContaining('you can still use engines shared'),
        findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.textContaining('Node setup stopped'), findsNothing);

    // Neutral surface, explicitly NOT the red error container.
    expect(_bannerColor(tester), scheme.surfaceContainerHighest);
    expect(_bannerColor(tester), isNot(scheme.errorContainer));
  });

  testWidgets('a genuine failure keeps the red error styling', (tester) async {
    await _pumpBanner(
      tester,
      const NodeSetupFailed(
        step: _llamaStep,
        message: 'engine install failed (exit 1).',
        log: [],
        kind: NodeSetupFailureKind.error,
      ),
    );

    expect(find.textContaining('Node setup stopped'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
    expect(_bannerColor(tester), scheme.errorContainer);
  });

  testWidgets('an idle setup renders nothing', (tester) async {
    await _pumpBanner(tester, const NodeSetupIdle());

    expect(find.byType(NodeSetupBanner), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });
}
