import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/code/logic/code_argv.dart';
import 'package:grid_app/features/code/logic/code_cli.dart';
import 'package:grid_app/features/code/logic/code_errors.dart';
import 'package:grid_app/features/code/logic/code_project.dart';
import 'package:grid_app/features/code/logic/code_projects_controller.dart';
import 'package:grid_app/features/code/logic/task_follow_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

const _grid = 'grid-1';

CliResult _ok(Object body) =>
    CliResult(exitCode: 0, stdout: jsonEncode(body), stderr: '');

ProviderContainer _containerWith(FakeGridCliService cli) {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      codeGridIdProvider.overrideWithValue(_grid),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The first error the project list reports — read off the provider's own
/// state, which is what the screen renders.
///
/// Deliberately **not** `await provider.future`: Riverpod retries a failed
/// provider ten times with a backoff before that future settles, so awaiting it
/// would spend half a minute proving something the first failure already
/// showed — and would then hand back its own wrapper rather than the error the
/// UI branches on.
Future<Object?> _failureOfProjectList(FakeGridCliService cli) async {
  final container = _containerWith(cli);
  final failed = Completer<Object?>();
  container.listen<AsyncValue<List<GridProject>>>(codeProjectsProvider, (
    _,
    next,
  ) {
    if (next.hasError && !failed.isCompleted) failed.complete(next.error);
  }, fireImmediately: true);
  return failed.future;
}

void main() {
  group('reading the grid’s answer', () {
    test('a project list comes back as projects', () async {
      final cli = FakeGridCliService()
        ..stubResult(
          projectListArgs(grid: _grid),
          _ok({
            'projects': [
              {'id': 'P1', 'name': 'my-app', 'role': 'owner'},
            ],
          }),
        );
      final container = _containerWith(cli);

      final projects = await container.read(codeProjectsProvider.future);

      expect(projects.single.name, 'my-app');
      expect(projects.single.isOwner, isTrue);
    });

    test(
      'a body that is not JSON is refused, never shown as an empty list',
      () async {
        // An empty project list and a mangled reply are two different answers,
        // and only one of them means "you have no projects".
        final cli = FakeGridCliService()
          ..stubResult(
            projectListArgs(grid: _grid),
            const CliResult(
              exitCode: 0,
              stdout: '<html>proxy</html>',
              stderr: '',
            ),
          );

        final failure = await _failureOfProjectList(cli);

        expect(failure, isA<CodeGridException>());
      },
    );

    test('a grid tool with no task commands is a state, not an error', () async {
      // Every action would otherwise fail with argparse's list of the commands
      // it *does* have, which reads as something being broken — so the screen
      // has to be able to tell this one apart and offer an update instead.
      final cli = FakeGridCliService()
        ..stubResult(
          projectListArgs(grid: _grid),
          const CliResult(
            exitCode: 2,
            stdout: '',
            stderr: "invalid choice: 'project' (choose from 'join')",
          ),
        );

      expect(await _failureOfProjectList(cli), isA<CodeCliTooOld>());
    });

    test('the capability probe answers from `task --help` alone', () async {
      final cli = FakeGridCliService()
        ..stubResult(
          ['task', '--help'],
          const CliResult(exitCode: 0, stdout: 'usage: grid task', stderr: ''),
        );
      final container = _containerWith(cli);

      expect(await container.read(codeCliSupportedProvider.future), isTrue);
    });
  });

  group('watching a task', () {
    test('events arrive in order and the terminal one ends the view', () async {
      final cli = FakeGridCliService()
        ..stubStart(
          taskFollowArgs(taskId: 't-1', grid: _grid),
          lines: [
            CliLine(
              isStderr: false,
              text: jsonEncode({
                'seq': 1,
                'event': {
                  'type': 'task.tool_use',
                  'tool': 'Edit',
                  'path': 'a.py',
                },
              }),
            ),
            // The CLI's own diagnostics ride stderr; they are not events, and
            // parsing them as such would be guesswork.
            const CliLine(isStderr: true, text: 'connection lost; reattaching'),
            CliLine(
              isStderr: false,
              text: jsonEncode({
                'seq': 2,
                'event': {'type': 'task.terminal', 'state': 'completed'},
              }),
            ),
          ],
        );
      final container = _containerWith(cli);

      final feed = taskFollowProvider('t-1');
      container.listen(feed, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final state = container.read(feed);
      expect(state.events.map((event) => event.seq), [1, 2]);
      expect(state.status, isA<FollowFinished>());
      expect((state.status as FollowFinished).terminal.state.wire, 'completed');
    });

    test(
      'a stream that ends with no verdict gives up rather than spinning',
      () async {
        // The CLI already reattaches at the cursor five times; this is the outer
        // bound on that, so a relay genuinely gone ends up on screen as "lost".
        final cli = FakeGridCliService()
          ..stubStart(
            taskFollowArgs(taskId: 't-2', grid: _grid),
            lines: [],
          );
        final container = _containerWith(cli);

        final feed = taskFollowProvider('t-2');
        container.listen(feed, (_, _) {});
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(container.read(feed).status, isA<FollowLost>());
      },
    );
  });

  group('creating things', () {
    test('a project the grid accepts without an id is refused loudly', () async {
      // Nothing downstream can recover: a task would be posted with no project
      // and refused with a message about a key the user never typed.
      final cli = FakeGridCliService()
        ..stubResult(
          projectCreateArgs(name: 'my-app', grid: _grid),
          _ok({'name': 'my-app'}),
        );
      final container = _containerWith(cli);

      await expectLater(
        container.read(codeProjectsProvider.notifier).create('my-app'),
        throwsA(isA<CodeGridException>()),
      );
    });

    test(
      'a created project is opened and listed without a manual refresh',
      () async {
        final cli = FakeGridCliService()
          ..stubResult(
            projectCreateArgs(name: 'my-app', grid: _grid),
            _ok({'id': 'P9', 'name': 'my-app'}),
          )
          ..stubResult(
            projectListArgs(grid: _grid),
            _ok({
              'projects': [
                {'id': 'P9', 'name': 'my-app'},
              ],
            }),
          );
        final container = _containerWith(cli);
        await container.read(codeProjectsProvider.future);

        final project = await container
            .read(codeProjectsProvider.notifier)
            .create('my-app');

        expect(project.id, 'P9');
        expect(
          container.read(codeProjectsProvider).value,
          contains(isA<GridProject>().having((p) => p.id, 'id', 'P9')),
        );
      },
    );
  });
}
