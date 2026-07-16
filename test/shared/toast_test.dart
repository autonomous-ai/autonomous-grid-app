import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/widgets/toast.dart';

/// Pumps a ToastScope over a trivial home, and hands back a context under it.
Future<BuildContext> _pumpScope(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      home: ToastScope(
        child: Builder(
          builder: (context) {
            ctx = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    ),
  );
  return ctx;
}

void main() {
  testWidgets('shows the message it was given', (tester) async {
    final ctx = await _pumpScope(tester);

    ToastScope.show(ctx, const ToastSpec(message: 'Grid created.'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Grid created.'), findsOneWidget);
  });

  testWidgets('a toast fired right after Navigator.pop still appears', (
    tester,
  ) async {
    // The regression that shipped: confirming a dialog and *then* reporting the
    // outcome is the natural way to write this, but it left the toast reaching
    // for a context that had just been deactivated — and it silently no-oped.
    final ctx = await _pumpScope(tester);

    openPopThenToastDialog(ctx);
    await tester.pumpAndSettle();
    expect(find.text('In a dialog'), findsOneWidget);

    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(find.text('In a dialog'), findsNothing, reason: 'dialog popped');
    expect(find.text('Saved.'), findsOneWidget);
  });

  testWidgets('severity picks the colour and the icon', (tester) async {
    final ctx = await _pumpScope(tester);

    ToastScope.showResult(ctx, error: 'It broke.', success: 'unused');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('It broke.'), findsOneWidget);
    expect(find.byIcon(ToastSeverity.error.icon), findsOneWidget);

    // ...and the success arm is visibly a different toast.
    expect(find.byIcon(ToastSeverity.success.icon), findsNothing);
  });

  testWidgets('a second toast queues rather than clobbering the first', (
    tester,
  ) async {
    final ctx = await _pumpScope(tester);

    ToastScope.show(ctx, const ToastSpec(message: 'First'));
    ToastScope.show(ctx, const ToastSpec(message: 'Second'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsNothing, reason: 'queued behind First');

    // First expires (4s) and unwinds; Second takes the stage.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('it clears itself once its time is up', (tester) async {
    final ctx = await _pumpScope(tester);

    ToastScope.show(ctx, const ToastSpec(message: 'Transient'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Transient'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Transient'), findsNothing);
  });

  testWidgets('an action fires and dismisses the toast', (tester) async {
    final ctx = await _pumpScope(tester);
    var pressed = false;

    ToastScope.show(
      ctx,
      ToastSpec(
        message: 'Update available',
        action: ToastAction(
          label: 'Download',
          onPressed: () => pressed = true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(pressed, isTrue);
    expect(find.text('Update available'), findsNothing);
  });
}

/// Opens a dialog whose Confirm pops first and toasts second — the exact
/// ordering that broke.
void openPopThenToastDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('In a dialog'),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            ToastScope.show(
              dialogContext,
              const ToastSpec(
                message: 'Saved.',
                severity: ToastSeverity.success,
              ),
            );
          },
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}
