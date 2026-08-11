import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/task_serving_store.dart';

void main() {
  group('the environment that makes this computer a task provider', () {
    test('nothing at all is sent while serving is off', () {
      // The variable's absence is what the CLI reads as off. Sending a "no" is
      // one more thing that can be spelled wrong.
      expect(taskServingEnv(const TaskServingPrefs()), isEmpty);
    });

    test('opting in sends the flag the CLI actually gates on', () {
      final env = taskServingEnv(const TaskServingPrefs(enabled: true));
      expect(env['GRID_TASKS'], '1');
      expect(env['GRID_MAX_TASKS'], '1');
    });

    test('a workspace root is only sent when one was chosen', () {
      // Writing the CLI's own default back as an explicit value would pin this
      // app to a path the CLI is free to change.
      expect(
        taskServingEnv(const TaskServingPrefs(enabled: true)),
        isNot(contains('GRID_TASK_ROOT')),
      );
      expect(
        taskServingEnv(
          const TaskServingPrefs(enabled: true, workspaceRoot: '/var/grid'),
        )['GRID_TASK_ROOT'],
        '/var/grid',
      );
    });

    test('the Claude config dir is never set, on any platform', () {
      // On macOS the credential lives in the Keychain, and setting this — even
      // to its own default path — makes Claude Code look for a credentials
      // file that is not there. Every task then fails with an empty message.
      final env = taskServingEnv(
        const TaskServingPrefs(enabled: true, maxTasks: 2),
      );
      expect(env.containsKey('GRID_TASK_CLAUDE_CONFIG_DIR'), isFalse);
    });

    test('a concurrency below one is corrected rather than passed on', () {
      // Zero would read to the CLI as "claim nothing" while the app showed the
      // switch as on.
      expect(
        taskServingEnv(
          const TaskServingPrefs(enabled: true, maxTasks: 0),
        )['GRID_MAX_TASKS'],
        '1',
      );
    });
  });

  group('remembering the answer across restarts', () {
    late Directory dir;
    late TaskServingStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('grid-task-serving');
      store = TaskServingStore(file: File('${dir.path}/task_serving.json'));
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('a saved choice comes back as it was left', () {
      store.save(
        const TaskServingPrefs(
          enabled: true,
          maxTasks: 3,
          workspaceRoot: '/tmp/work',
        ),
      );
      final loaded = store.load();
      expect(loaded.enabled, isTrue);
      expect(loaded.maxTasks, 3);
      expect(loaded.workspaceRoot, '/tmp/work');
    });

    test('no file yet means not serving — the safe answer', () {
      // Guessing the other way spends somebody's Claude subscription without
      // being asked.
      expect(store.load().enabled, isFalse);
    });

    test('a corrupt file reads as not serving rather than throwing', () {
      File('${dir.path}/task_serving.json').writeAsStringSync('{{{');
      expect(store.load().enabled, isFalse);
    });

    test('a hand-edited zero concurrency is clamped on the way in', () {
      File(
        '${dir.path}/task_serving.json',
      ).writeAsStringSync('{"enabled": true, "max_tasks": 0}');
      expect(store.load().maxTasks, 1);
    });
  });
}
