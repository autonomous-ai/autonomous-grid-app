import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/code/logic/code_argv.dart';

const _grid = 'grid-1';
const _project = 'p-1';

void main() {
  group('every command names the grid and asks for JSON', () {
    test('so a grid switched mid-screen cannot be acted on by mistake', () {
      // Left to the CLI's "active grid" these would follow ~/.grid/state.json,
      // which the user can flip from their own terminal while a screen is open.
      final commands = [
        projectListArgs(grid: _grid),
        projectCreateArgs(name: 'x', grid: _grid),
        projectStatusArgs(projectId: _project, grid: _grid),
        projectCheckArgs(projectId: _project, grid: _grid),
        projectIntegrateArgs(projectId: _project, grid: _grid),
        projectPromoteArgs(projectId: _project, memberKey: 'k', grid: _grid),
        projectImportArgs(path: '.', projectId: _project, grid: _grid),
        projectCloneArgs(projectId: _project, directory: '/d', grid: _grid),
        projectCommitArgs(
          projectId: _project,
          message: 'm',
          grid: _grid,
          files: ['a.txt'],
        ),
        memberListArgs(projectId: _project, grid: _grid),
        memberAddArgs(projectId: _project, email: 'a@b.c', grid: _grid),
        memberRemoveArgs(projectId: _project, memberKey: 'k', grid: _grid),
        taskListArgs(projectId: _project, grid: _grid),
        taskCreateArgs(projectId: _project, prompt: 'go', grid: _grid),
        taskGetArgs(taskId: 't', grid: _grid),
        taskFollowArgs(taskId: 't', grid: _grid),
        taskFetchArgs(taskId: 't', into: '/d', grid: _grid),
        taskCancelArgs(taskId: 't', grid: _grid),
      ];
      for (final command in commands) {
        expect(
          command,
          containsAllInOrder(['--grid', _grid]),
          reason: '$command',
        );
        expect(command, contains('--json'), reason: '$command');
      }
    });
  });

  group('the two commands whose argument shape is easy to confuse', () {
    test('promote takes a member key positionally — it names whose branch', () {
      expect(
        projectPromoteArgs(projectId: _project, memberKey: 'abc', grid: _grid),
        containsAllInOrder(['promote', _project, 'abc']),
      );
    });

    test('integrate takes no member key — the relay holds *your* slot', () {
      // Naming somebody else's branch would take the wrong person's task slot
      // while moving a ref their running task was cut from.
      expect(
        projectIntegrateArgs(projectId: _project, grid: _grid),
        isNot(contains('abc')),
      );
    });

    test(
      'a project member is admitted by an --email flag, not a positional',
      () {
        // `grid members add <grid> <email>` takes it positionally; this one does
        // not, and the pair is the CLI guide's own example of an easy mix-up.
        expect(
          memberAddArgs(projectId: _project, email: 'a@b.c', grid: _grid),
          containsAllInOrder(['add', _project, '--email', 'a@b.c']),
        );
      },
    );

    test('a member is removed by key, because a user id is not a path', () {
      expect(
        memberRemoveArgs(projectId: _project, memberKey: 'abc', grid: _grid),
        containsAllInOrder(['remove', _project, 'abc']),
      );
    });
  });

  group('task list', () {
    test('asks for the whole team by default off, and --all when told', () {
      expect(
        taskListArgs(projectId: _project, grid: _grid),
        isNot(contains('--all')),
      );
      expect(
        taskListArgs(projectId: _project, grid: _grid, all: true),
        contains('--all'),
      );
    });

    test('repeats --state per filter, which is how the CLI takes them', () {
      expect(
        taskListArgs(
          projectId: _project,
          grid: _grid,
          states: ['queued', 'running'],
        ),
        containsAllInOrder(['--state', 'queued', '--state', 'running']),
      );
    });

    test(
      'leaves the page cursor off when there is nothing to continue from',
      () {
        expect(
          taskListArgs(projectId: _project, grid: _grid, after: ''),
          isNot(contains('--after')),
        );
      },
    );
  });

  group('uploads', () {
    test('each file is its own --file, so one bad path is one refusal', () {
      expect(
        taskCreateArgs(
          projectId: _project,
          prompt: 'go',
          grid: _grid,
          files: ['a.txt', 'b.txt'],
        ),
        containsAllInOrder(['--file', 'a.txt', '--file', 'b.txt']),
      );
    });

    test('a destination is appended, never substituted for the local path', () {
      // The CLI splits on the LAST colon, so the local half keeps any colons of
      // its own — a path split on the first would send it hunting for './od'.
      expect(
        fileSpec('./od:2026-08-04.csv', destination: 'notes/od.csv'),
        './od:2026-08-04.csv:notes/od.csv',
      );
    });

    test(
      'no destination leaves the spec bare, so the CLI uses the basename',
      () {
        expect(fileSpec('/tmp/conf.toml'), '/tmp/conf.toml');
        expect(fileSpec('/tmp/conf.toml', destination: ''), '/tmp/conf.toml');
      },
    );
  });

  group('commit', () {
    test('writes and deletes travel together, each repeated per path', () {
      expect(
        projectCommitArgs(
          projectId: _project,
          message: 'fix',
          grid: _grid,
          files: ['a.py'],
          deletes: ['old.py'],
        ),
        containsAllInOrder([
          '-m',
          'fix',
          '--file',
          'a.py',
          '--delete',
          'old.py',
        ]),
      );
    });
  });

  group('follow', () {
    test(
      'resumes at the cursor, so a remade stream has no gap and no repeat',
      () {
        expect(
          taskFollowArgs(taskId: 't', grid: _grid, afterSeq: 42),
          containsAllInOrder(['--after-seq', '42']),
        );
      },
    );

    test('starts from the beginning when nothing has been seen yet', () {
      expect(
        taskFollowArgs(taskId: 't', grid: _grid),
        containsAllInOrder(['--after-seq', '-1']),
      );
    });
  });

  group('import', () {
    test('defaults to HEAD, so whatever is checked out is what travels', () {
      expect(
        projectImportArgs(path: '/repo', projectId: _project, grid: _grid),
        containsAllInOrder(['import', '/repo', _project, '--branch', 'HEAD']),
      );
    });
  });
}
