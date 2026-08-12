import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/grid_paths.dart';
import 'package:grid_app/features/code/logic/code_argv.dart';
import 'package:grid_app/features/code/logic/code_errors.dart';
import 'package:grid_app/features/code/logic/code_projects_controller.dart';
import 'package:grid_app/features/code/logic/code_tasks_controller.dart';
import 'package:grid_app/features/code/logic/project_flow.dart';
import 'package:grid_app/features/code/logic/project_status_controller.dart';
import 'package:grid_app/infrastructure/cli/fake_grid_cli_service.dart';
import 'package:grid_app/infrastructure/cli/grid_cli_service.dart';
import 'package:grid_app/infrastructure/providers.dart';

const _grid = 'grid-1';
const _project = 'P1';
const _member = 'MK';
const _projectName = 'mac-e2e';

/// Where the flow keeps this project's working copy — the fixed, app-owned path
/// it clones into after a task ships. Computed the same way the flow does, from
/// the project's name.
String get _copyDir => GridPaths.projectCodeDir(
  cloneFolderName(projectName: _projectName, projectId: _project),
).path;

List<String> get _clone =>
    projectCloneArgs(projectId: _project, directory: _copyDir, grid: _grid);
List<String> get _projectList => projectListArgs(grid: _grid);

CliResult _ok(Object body) =>
    CliResult(exitCode: 0, stdout: jsonEncode(body), stderr: '');

List<String> get _check => projectCheckArgs(projectId: _project, grid: _grid);
List<String> get _integrate =>
    projectIntegrateArgs(projectId: _project, grid: _grid);
List<String> _create(String prompt) =>
    taskCreateArgs(projectId: _project, prompt: prompt, grid: _grid);
List<String> get _promote =>
    projectPromoteArgs(projectId: _project, memberKey: _member, grid: _grid);
List<String> get _list =>
    taskListArgs(projectId: _project, grid: _grid, all: true);
List<String> get _status => projectStatusArgs(projectId: _project, grid: _grid);

/// A status the flow can read a member key out of — what promote needs.
CliResult _statusReply() => _ok({
  'project_id': _project,
  'branch': 'wip/$_member',
  'member_key': _member,
  'main_commit': 'a' * 40,
});

CliResult _tasks(List<Map<String, dynamic>> tasks) => _ok({'tasks': tasks});

/// A fake stubbed for the whole happy path, so each test overrides only the
/// one reply it is about.
FakeGridCliService _cli() => FakeGridCliService()
  ..stubResult(_check, _ok({'status': 'up_to_date', 'branch': 'wip/$_member'}))
  ..stubResult(_status, _statusReply())
  ..stubResult(_list, _tasks([]))
  ..stubResult(
    _projectList,
    _ok({
      'projects': [
        {'id': _project, 'name': _projectName},
      ],
    }),
  )
  ..stubResult(
    _clone,
    _ok({'path': _copyDir, 'branch': 'wip/$_member', 'trunk': 'main'}),
  )
  ..stubResult(
    _promote,
    _ok({
      'branch': 'main',
      'advanced': true,
      'commit': 'b' * 40,
      'promotion_id': 'r1',
    }),
  );

Future<ProviderContainer> _open(FakeGridCliService cli) async {
  final container = ProviderContainer(
    overrides: [
      gridCliServiceProvider.overrideWithValue(cli),
      codeGridIdProvider.overrideWithValue(_grid),
    ],
  );
  addTearDown(container.dispose);
  // Build the flow (which listens to the task list) and prime the reads a
  // submit runs against: the two polled ones, and the project list the flow
  // reads the name out of to place the on-disk copy.
  container.listen(projectFlowProvider(_project), (_, _) {});
  container.listen(codeProjectsProvider, (_, _) {});
  await container.read(codeTasksProvider(_project).future);
  await container.read(projectStatusProvider(_project).future);
  await container.read(codeProjectsProvider.future);
  return container;
}

ProjectFlow _flow(ProviderContainer c) =>
    c.read(projectFlowProvider(_project).notifier);

/// Whether the fake was asked to run [args] — compared by content, since two
/// argv lists of equal contents are still different `List` instances.
bool _ran(FakeGridCliService cli, List<String> args) =>
    cli.runCalls.any((call) => call.join(' ') == args.join(' '));

/// Let the unawaited publish that `_onTasks` fires run to completion.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  group('catching up before the task', () {
    test('the trunk is brought in before the task is created', () async {
      final cli = _cli()
        ..stubResult(
          _check,
          _ok({'status': 'fast_forward', 'branch': 'wip/$_member'}),
        )
        ..stubResult(
          _integrate,
          _ok({
            'status': 'fast_forward',
            'branch': 'wip/$_member',
            'commit': 'c' * 40,
          }),
        )
        ..stubResult(_create('go'), _ok({'id': 'T1', 'state': 'queued'}));
      final container = await _open(cli);

      await _flow(container).submit(prompt: 'go', files: const []);

      final integrateAt = cli.runCalls.indexWhere(
        (c) => c.contains('integrate'),
      );
      final createAt = cli.runCalls.indexWhere((c) => c.contains('create'));
      expect(integrateAt, greaterThanOrEqualTo(0), reason: 'integrate ran');
      expect(createAt, greaterThan(integrateAt), reason: 'create came after');
    });

    test('an up-to-date branch is not integrated needlessly', () async {
      // Integrating an up-to-date branch inserts a task row to hold the slot for
      // nothing, so the free check is what decides whether to spend it.
      final cli = _cli()
        ..stubResult(_create('go'), _ok({'id': 'T1', 'state': 'queued'}));
      final container = await _open(cli);

      await _flow(container).submit(prompt: 'go', files: const []);

      expect(cli.runCalls.any((c) => c.contains('integrate')), isFalse);
    });

    test('a conflict on catch-up is thrown, and the task is not sent', () async {
      // The merge that resolves a conflict takes this member's one slot, so the
      // task they asked for cannot be created behind it — the flow hands the
      // text back rather than half-sending it.
      final cli = _cli()
        ..stubResult(
          _check,
          _ok({'status': 'merge_task', 'branch': 'wip/$_member'}),
        )
        ..stubResult(
          _integrate,
          _ok({
            'status': 'merge_task',
            'branch': 'wip/$_member',
            'task_id': 'M1',
          }),
        )
        ..stubResult(_create('go'), _ok({'id': 'T1', 'state': 'queued'}));
      final container = await _open(cli);

      await expectLater(
        _flow(container).submit(prompt: 'go', files: const []),
        throwsA(isA<CodeGridException>()),
      );
      expect(cli.runCalls.any((c) => c.contains('create')), isFalse);
    });
  });

  group('publishing when the task lands', () {
    test('a completed task is promoted on its own', () async {
      final cli = _cli()
        ..stubResult(_create('go'), _ok({'id': 'T1', 'state': 'queued'}))
        // The list the flow reads back after create already shows it done.
        ..stubResult(_list, _tasks([_done('T1')]));
      final container = await _open(cli);

      await _flow(container).submit(prompt: 'go', files: const []);
      await _settle();

      expect(_ran(cli, _promote), isTrue);
      expect(
        container.read(projectFlowProvider(_project)).notice?.level,
        FlowLevel.success,
      );
    });

    test('shipping a task refreshes the copy at ~/.grid/app/code', () async {
      // The third button, made automatic: once code lands on the team, the
      // on-disk copy is brought up to it, at the app's own fixed path.
      final cli = _cli()
        ..stubResult(_create('go'), _ok({'id': 'T1', 'state': 'queued'}))
        ..stubResult(_list, _tasks([_done('T1')]));
      final container = await _open(cli);

      await _flow(container).submit(prompt: 'go', files: const []);
      await _settle();

      expect(_ran(cli, _clone), isTrue);
      expect(_copyDir, endsWith('/app/code/$_projectName'));
    });

    test('a publish that moved nothing does not re-clone', () async {
      // A no-op publish (the task wrote nothing new) leaves the copy already
      // current, so there is nothing to fetch.
      final cli = _cli()
        ..stubResult(_create('go'), _ok({'id': 'T1', 'state': 'queued'}))
        ..stubResult(_list, _tasks([_done('T1')]))
        ..stubResult(
          _promote,
          _ok({'branch': 'main', 'advanced': false, 'commit': 'b' * 40}),
        );
      final container = await _open(cli);

      await _flow(container).submit(prompt: 'go', files: const []);
      await _settle();

      expect(_ran(cli, _promote), isTrue);
      expect(_ran(cli, _clone), isFalse);
    });

    test('a task that failed is never published', () async {
      final cli = _cli()
        ..stubResult(_create('go'), _ok({'id': 'T1', 'state': 'queued'}))
        ..stubResult(
          _list,
          _tasks([
            {'id': 'T1', 'state': 'failed', 'prompt': 'go'},
          ]),
        );
      final container = await _open(cli);

      await _flow(container).submit(prompt: 'go', files: const []);
      await _settle();

      expect(_ran(cli, _promote), isFalse);
      expect(
        container.read(projectFlowProvider(_project)).notice?.level,
        FlowLevel.warning,
      );
    });

    test(
      'a state this build cannot read keeps waiting, it is not published',
      () async {
        // Unknown is deliberately not terminal: the task may still be running,
        // and publishing an unfinished branch is exactly the wrong move.
        final cli = _cli()
          ..stubResult(_create('go'), _ok({'id': 'T1', 'state': 'queued'}))
          ..stubResult(
            _list,
            _tasks([
              {'id': 'T1', 'state': 'reticulating', 'prompt': 'go'},
            ]),
          );
        final container = await _open(cli);

        await _flow(container).submit(prompt: 'go', files: const []);
        await _settle();

        expect(_ran(cli, _promote), isFalse);
        expect(
          container.read(projectFlowProvider(_project)).awaitingPublish,
          contains('T1'),
        );
      },
    );

    test('a refused publish is surfaced, not swallowed or retried', () async {
      // The team's main moved while the task ran, so a fast-forward is refused.
      // Publish has no undo, so the honest thing is to hand it back rather than
      // keep trying behind the user's back.
      final cli = _cli()
        ..stubResult(_create('go'), _ok({'id': 'T1', 'state': 'queued'}))
        ..stubResult(_list, _tasks([_done('T1')]))
        ..stubResult(
          _promote,
          const CliResult(
            exitCode: 1,
            stdout: '',
            stderr: 'Behind main, so a promote would be refused.',
          ),
        );
      final container = await _open(cli);

      await _flow(container).submit(prompt: 'go', files: const []);
      await _settle();

      final notice = container.read(projectFlowProvider(_project)).notice;
      expect(notice?.level, FlowLevel.error);
      expect(notice?.message, contains('couldn’t be published'));
    });
  });
}

Map<String, dynamic> _done(String id) => {
  'id': id,
  'state': 'completed',
  'prompt': 'go',
  'branch': 'task/$id',
};
