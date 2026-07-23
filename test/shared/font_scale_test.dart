import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';
import 'package:grid_app/shared/widgets/code_text_scope.dart';
import 'package:grid_app/shared/widgets/labeled_field.dart';

/// What the UI font size does to the boxes it grows inside.
///
/// The whole design rests on one bet: that `MediaQuery`'s text scaler can carry
/// the setting to 249 `fontSize` literals without any of them being edited, and
/// that the app's fixed-height controls can be grown to match. This file is
/// where that bet is checked — by *measuring* rects, not by reading the code and
/// reasoning about what it should produce.
///
/// It cannot check what the type looks like: the headless font manager resolves
/// every family to the same test face, so "did the font actually change" is a
/// question only a screenshot of the running app can answer. What it can check
/// is geometry, and geometry is where a font setting breaks a layout.
void main() {
  setUp(AppFont.reset);
  tearDown(AppFont.reset);

  /// The app as it is really assembled: settings pushed onto AppFont *before*
  /// the theme is built (buildAppTheme reads them), and the scale applied over
  /// the whole app the way `GridApp` does it.
  Widget host(Widget child, {double uiSize = 14, double codeSize = 12.5}) {
    final scale = uiSize / 14;
    AppTheme.fonts.apply(uiScale: scale, codeSize: codeSize);
    return MaterialApp(
      theme: buildAppTheme(),
      builder: (context, inner) => MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: inner ?? const SizedBox.shrink(),
      ),
      home: BrightnessScope(
        child: Scaffold(body: Center(child: child)),
      ),
    );
  }

  group('a button grows with the type it holds', () {
    testWidgets('the label and the box both grow, and the label still fits', (
      tester,
    ) async {
      Future<(Rect box, Rect label)> measure(double uiSize) async {
        await tester.pumpWidget(
          host(
            FilledButton(onPressed: () {}, child: const Text('Save changes')),
            uiSize: uiSize,
          ),
        );
        await tester.pumpAndSettle();
        return (
          tester.getRect(find.byType(FilledButton)),
          tester.getRect(find.text('Save changes')),
        );
      }

      final (smallBox, smallLabel) = await measure(11);
      final (bigBox, bigLabel) = await measure(19);

      expect(
        bigLabel.width,
        greaterThan(smallLabel.width),
        reason: 'the text scaler has to reach a button label',
      );
      expect(
        bigBox.height,
        greaterThan(smallBox.height),
        reason: 'the box must grow too, or the label outgrows its capsule',
      );
      // The real failure mode: text wider or taller than the box holding it.
      expect(bigLabel.width, lessThanOrEqualTo(bigBox.width));
      expect(bigLabel.height, lessThanOrEqualTo(bigBox.height));
      expect(smallLabel.width, lessThanOrEqualTo(smallBox.width));
      expect(smallLabel.height, lessThanOrEqualTo(smallBox.height));
    });

    testWidgets('the height tracks the setting proportionally', (tester) async {
      Future<double> heightAt(double uiSize) async {
        await tester.pumpWidget(
          host(
            FilledButton(onPressed: () {}, child: const Text('OK')),
            uiSize: uiSize,
          ),
        );
        await tester.pumpAndSettle();
        return tester.getRect(find.byType(FilledButton)).height;
      }

      final base = await heightAt(14);
      final big = await heightAt(19);
      expect(base, AppControl.height);
      expect(big, closeTo(AppControl.height * (19 / 14), 0.01));
    });
  });

  group('a field grows with the type it holds', () {
    testWidgets('the box grows and the text stays inside it', (tester) async {
      final controller = TextEditingController(text: 'grid.local');
      addTearDown(controller.dispose);

      Future<(Rect, Rect)> measure(double uiSize) async {
        await tester.pumpWidget(
          host(
            SizedBox(
              width: 320,
              child: LabeledField(
                label: 'Host',
                controller: controller,
                hint: 'hostname',
              ),
            ),
            uiSize: uiSize,
          ),
        );
        await tester.pumpAndSettle();
        return (
          tester.getRect(find.byType(TextField)),
          tester.getRect(find.text('grid.local')),
        );
      }

      final (smallBox, smallText) = await measure(11);
      final (bigBox, bigText) = await measure(19);

      expect(bigBox.height, greaterThan(smallBox.height));
      expect(bigText.height, greaterThan(smallText.height));
      expect(
        bigText.height,
        lessThanOrEqualTo(bigBox.height),
        reason: 'typed text taller than its own field is the visible break',
      );
    });
  });

  group('code is sized on its own', () {
    // `AppFont.codeStyle()` has to be read *inside* the build, not captured
    // when the widget is constructed — the settings are pushed onto AppFont by
    // `host` and a style resolved before that call carries the previous size.
    // That is exactly why every code surface in the app resolves its style in
    // `build` rather than holding one in a field.
    Widget codeSample() =>
        Builder(builder: (_) => Text('0O1lI', style: AppFont.codeStyle()));

    // The two settings must not multiply. Without CodeTextScope they would: a
    // block would take AppFont.codeSize *and* the UI text scaler, so UI 19 with
    // code 12 renders code at ~16.
    testWidgets('the UI scale does not reach a code surface', (tester) async {
      Future<double> codeHeightAt(double uiSize) async {
        await tester.pumpWidget(
          host(
            CodeTextScope(child: codeSample()),
            uiSize: uiSize,
            codeSize: 12,
          ),
        );
        await tester.pumpAndSettle();
        return tester.getRect(find.text('0O1lI')).height;
      }

      expect(await codeHeightAt(19), await codeHeightAt(11));
    });

    testWidgets('the code setting alone changes a code surface', (
      tester,
    ) async {
      Future<double> codeHeightAt(double codeSize) async {
        await tester.pumpWidget(
          host(CodeTextScope(child: codeSample()), codeSize: codeSize),
        );
        await tester.pumpAndSettle();
        return tester.getRect(find.text('0O1lI')).height;
      }

      expect(await codeHeightAt(18), greaterThan(await codeHeightAt(10)));
    });

    // Inline code is the other half of the rule: a `token` inside a sentence
    // does follow the UI scale, or it steps out of the line it belongs to.
    testWidgets('inline code, outside the scope, does follow the UI scale', (
      tester,
    ) async {
      Future<double> heightAt(double uiSize) async {
        await tester.pumpWidget(host(codeSample(), uiSize: uiSize));
        await tester.pumpAndSettle();
        return tester.getRect(find.text('0O1lI')).height;
      }

      expect(await heightAt(19), greaterThan(await heightAt(11)));
    });
  });

  group('the chosen family reaches the tokens', () {
    testWidgets('a chosen UI family leads, with the system font behind it', (
      tester,
    ) async {
      await tester.pumpWidget(host(const SizedBox.shrink()));
      expect(AppFont.sans, AppFont.sansDefault);
      expect(AppFont.sansFallback.first, 'SF Pro Text');

      AppTheme.fonts.apply(uiFamily: 'Inter', uiScale: 1, codeSize: 12.5);
      expect(AppFont.sans, 'Inter');
      expect(
        AppFont.sansFallback.first,
        AppFont.sansDefault,
        reason:
            'a partial face must degrade to the font the app was drawn in, '
            'not to Arial',
      );
    });

    testWidgets('a chosen code family leads, with system mono behind it', (
      tester,
    ) async {
      await tester.pumpWidget(host(const SizedBox.shrink()));
      AppTheme.fonts.apply(codeFamily: 'Menlo', uiScale: 1, codeSize: 12.5);

      expect(AppFont.mono, 'Menlo');
      expect(AppFont.monoFallback.first, AppFont.monoDefault);
      expect(
        AppFont.codeStyle().fontFamily,
        'Menlo',
        reason: 'codeStyle is what every code surface actually reads',
      );
    });

    testWidgets('the theme itself is built in the chosen family', (
      tester,
    ) async {
      AppFont.apply(uiFamily: 'Inter', uiScale: 1, codeSize: 12.5);
      final theme = buildAppTheme();
      expect(theme.textTheme.bodyMedium!.fontFamily, 'Inter');
      expect(
        theme.filledButtonTheme.style!.textStyle!.resolve({})!.fontFamily,
        'Inter',
        reason:
            'a ButtonStyle does not inherit fontFamily from the text theme — '
            'it has to be handed the family separately',
      );
    });
  });

  group('the notifier', () {
    test('only fires when something actually changed', () {
      var fired = 0;
      void listener() => fired++;
      AppTheme.fonts.addListener(listener);
      addTearDown(() => AppTheme.fonts.removeListener(listener));

      AppTheme.fonts.apply(uiFamily: 'Inter', uiScale: 1, codeSize: 12.5);
      expect(fired, 1);

      AppTheme.fonts.apply(uiFamily: 'Inter', uiScale: 1, codeSize: 12.5);
      expect(fired, 1, reason: 'the same settings must not dirty the tree');

      AppTheme.fonts.apply(uiFamily: 'Inter', uiScale: 1.2, codeSize: 12.5);
      expect(fired, 2);
    });
  });

  group('a widget behind a const boundary', () {
    // The reason AppTheme.watch exists. The app is full of `const` chrome, and
    // a const child is reference-identical across its parent's rebuild — so a
    // top-down rebuild never reaches it, and it would stay on whichever font it
    // first built with. The InheritedNotifier marks it dirty directly.
    testWidgets('still rebuilds when the font changes', (tester) async {
      _FontLeaf.builds = 0;
      _FontLeaf.lastFamily = null;

      await tester.pumpWidget(host(const _ConstParent()));
      await tester.pumpAndSettle();

      final before = _FontLeaf.builds;
      expect(_FontLeaf.lastFamily, AppFont.sansDefault);

      AppTheme.fonts.apply(uiFamily: 'Inter', uiScale: 1, codeSize: 12.5);
      await tester.pumpAndSettle();

      expect(_FontLeaf.builds, greaterThan(before));
      expect(_FontLeaf.lastFamily, 'Inter');
    });
  });
}

/// A `const` boundary, of exactly the kind the app's chrome is made of.
class _ConstParent extends StatelessWidget {
  const _ConstParent();

  @override
  Widget build(BuildContext context) => const _FontLeaf();
}

class _FontLeaf extends StatelessWidget {
  const _FontLeaf();

  static int builds = 0;
  static String? lastFamily;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    builds++;
    lastFamily = AppFont.sans;
    return Text('Aa', style: TextStyle(fontFamily: AppFont.sans));
  }
}
