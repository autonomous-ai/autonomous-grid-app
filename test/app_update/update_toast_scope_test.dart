import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/app_update/logic/app_updater_service.dart';
import 'package:grid_app/features/app_update/presentation/update_toast_scope.dart';

void main() {
  late StreamController<UpdateStatus> status;

  setUp(() => status = StreamController<UpdateStatus>());
  tearDown(() => status.close());

  Future<void> pumpScope(WidgetTester tester) => tester.pumpWidget(
        ProviderScope(
          overrides: [
            appUpdateStatusProvider.overrideWith((ref) => status.stream),
          ],
          child: const MaterialApp(
            home: UpdateToastScope(child: Scaffold(body: SizedBox.shrink())),
          ),
        ),
      );

  testWidgets('toasts an update-check outcome from anywhere in the app',
      (tester) async {
    await pumpScope(tester);

    status.add(const UpdateAvailable('0.3.0'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Update available: 0.3.0'), findsOneWidget);
  });

  testWidgets('a build with no update feed says so, and offers the download',
      (tester) async {
    await pumpScope(tester);

    status.add(const UpdateUnsupported());
    await tester.pump();
    await tester.pump();

    expect(find.textContaining("can't update itself"), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('the outcome replaces the in-flight "Checking…" toast',
      (tester) async {
    await pumpScope(tester);

    status.add(const UpdateChecking());
    await tester.pump();
    await tester.pump();
    status.add(const UpdateUpToDate());
    await tester.pump();
    // Let the outgoing snack bar finish its dismiss animation.
    await tester.pumpAndSettle();

    expect(find.text('Checking for updates…'), findsNothing);
    expect(find.text("You're on the latest version."), findsOneWidget);
  });
}
