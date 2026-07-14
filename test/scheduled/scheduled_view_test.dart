import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_providers.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/scheduled/logic/scheduled_jobs_controller.dart';
import 'package:grid_app/features/scheduled/logic/task_power_controller.dart';
import 'package:grid_app/features/scheduled/presentation/scheduled_view.dart';
import 'package:grid_app/infrastructure/cli/hermes_cron_service.dart';
import 'package:grid_app/infrastructure/cli/hermes_task_policy.dart';
import 'package:grid_app/shared/widgets/pill_choice.dart';

/// One saved task, no `hermes` process.
class _FakeCron implements HermesCronService {
  @override
  Future<String?> readJobsJson() async => '''
{"jobs": [{"id": "abc", "name": "Daily digest", "prompt": "Summarise",
  "schedule": {"expr": "0 8 * * 1-5"}, "enabled": true}]}
''';

  @override
  Future<List<CronOutput>> readOutputs(String jobId) async => const [];

  @override
  Future<void> create({
    required String schedule,
    required String prompt,
    required String name,
    String? workdir,
    String deliver = kDeliverLocal,
  }) async {}

  @override
  Future<void> pause(String id) async {}
  @override
  Future<void> resume(String id) async {}
  @override
  Future<void> remove(String id) async {}
  @override
  Future<void> runNow(String id) async {}
  @override
  Future<bool> schedulerRunning() async => true;
  @override
  Future<void> startScheduler() async {}
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_scheduled_view_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hermesPathProvider.overrideWithValue('/bin/hermes'),
          hermesCronServiceProvider.overrideWithValue(_FakeCron()),
          agentWorkspaceDirProvider.overrideWithValue(tmp),
          hermesTaskPolicyProvider.overrideWithValue(
            HermesTaskPolicy(home: tmp.path),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ScheduledView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('New task is the same height as the filters under it — Material '
      'pads a button out to a 48px tap target, which left the capsule floating '
      'in a box half again its own height', (tester) async {
    await pump(tester);

    final button = tester.getSize(find.byType(FilledButton));
    final pill = tester.getSize(find.byType(PillChoice).first);

    expect(find.widgetWithText(FilledButton, 'New task'), findsOneWidget);
    expect(button.height, pill.height);
    expect(button.height, lessThan(48), reason: 'no padded tap target');
  });
}
