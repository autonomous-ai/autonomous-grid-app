import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/agent_loop_guard.dart';

/// One write of [path], turning [before] into [after]. The contents are what
/// tells a loop from small steps, so most of these pass them.
AgentPermission _edit(String path, {String? before, String after = ''}) =>
    AgentPermission(
      id: path,
      kind: AgentPermissionKind.edit,
      summary: 'edit',
      path: path,
      oldText: before,
      newText: after,
      options: const [],
    );

AgentPermission _command(String command) => AgentPermission(
  id: command,
  kind: AgentPermissionKind.command,
  summary: 'run',
  command: command,
  options: const [],
);

AgentPermission _other() => const AgentPermission(
  id: 'x',
  kind: AgentPermissionKind.other,
  summary: 'something',
  options: [],
);

void main() {
  group('a file written back to where it was', () {
    test('back and forth between two versions, with nothing in between, is a '
        'circle — the third write has produced no version the file has not '
        'already held', () {
      final guard = AgentLoopGuard();
      const path = '/repo/plugins/cache.js';

      // Try something, then put it straight back: one undo is ordinary.
      expect(guard.observe(_edit(path, before: 'A', after: 'B')), isNull);
      expect(guard.observe(_edit(path, before: 'B', after: 'A')), isNull);
      expect(
        guard.observe(_edit(path, before: 'A', after: 'B')),
        'cache.js',
        reason: 'A→B→A→B is a circle however long you wait',
      );
    });

    test(
      'a check between two writes makes the same revert a bisect — the '
      'model learned something in between, which is the whole difference',
      () {
        final guard = AgentLoopGuard();
        const path = '/repo/plugins/cache.js';
        String? tripped;

        // try it → measure → put it back → measure → try it again
        for (var i = 0; i < 4; i++) {
          tripped ??= guard.observe(
            _edit(
              path,
              before: i.isEven ? 'A' : 'B',
              after: i.isEven ? 'B' : 'A',
            ),
          );
          tripped ??= guard.observe(_command('npm test $i'));
        }
        expect(tripped, isNull);
      },
    );

    test('writing the file it started with counts as a rewind — the contents '
        'it began with are a version it has already had', () {
      final guard = AgentLoopGuard();
      const path = '/repo/app.js';

      guard.observe(_edit(path, before: 'original', after: 'attempt'));
      // Straight back to the original: undo number one, and ordinary.
      expect(
        guard.observe(_edit(path, before: 'attempt', after: 'original')),
        isNull,
      );
      // And straight back to the attempt it had already made: nowhere.
      expect(
        guard.observe(_edit(path, before: 'original', after: 'attempt')),
        'app.js',
      );
    });

    test('an edit carrying no contents falls back to counting the path — with '
        'nothing to compare, a repeat is all there is to go on', () {
      final guard = AgentLoopGuard();
      const path = '/repo/schema.prisma';

      expect(guard.observe(_edit(path)), isNull);
      expect(guard.observe(_edit(path)), isNull);
      expect(guard.observe(_edit(path)), 'schema.prisma');
    });
  });

  group('a file written many times, saying something new each time', () {
    test('the small-step fix that used to be stopped mid-way now runs — eight '
        'hunks into one file is how a local model writes one change', () {
      final guard = AgentLoopGuard();
      const path = '/repo/plugins/cache.js';

      // The turn that was killed at 40 of 42 tests passing: four consecutive
      // writes, each a different hunk of the same fix.
      for (var i = 0; i < kMaxEditsInARow - 1; i++) {
        expect(
          guard.observe(_edit(path, before: 'v$i', after: 'v${i + 1}')),
          isNull,
          reason: 'write ${i + 1} of a fix is not a loop',
        );
      }
    });

    test('past the limit even fresh contents are a spin — nothing that writes '
        'one file this many times in a row is getting anywhere', () {
      final guard = AgentLoopGuard();
      const path = '/repo/plugins/cache.js';
      String? tripped;
      for (var i = 0; i < kMaxEditsInARow; i++) {
        tripped ??= guard.observe(
          _edit(path, before: 'v$i', after: 'v${i + 1}'),
        );
      }
      expect(tripped, 'cache.js');
    });

    test('any other target between resets the run, so a turn moving across a '
        'codebase is never stopped', () {
      final guard = AgentLoopGuard();
      String? tripped;
      // Twice the limit of writes to app.js, each separated by another file.
      for (var i = 0; i < kMaxEditsInARow * 2; i++) {
        tripped ??= guard.observe(
          _edit('/repo/app.js', before: 'a$i', after: 'a${i + 1}'),
        );
        tripped ??= guard.observe(
          _edit('/repo/routes/root.js', before: 'r$i', after: 'r${i + 1}'),
        );
      }
      expect(tripped, isNull);
    });

    test('each file is counted on its own — a turn touching many files a few '
        'times each is progress', () {
      final guard = AgentLoopGuard();
      for (final path in ['/a.js', '/b.js', '/c.js', '/.env']) {
        for (var i = 0; i < 3; i++) {
          expect(
            guard.observe(_edit(path, before: 'v$i', after: 'v${i + 1}')),
            isNull,
          );
        }
      }
    });
  });

  group('commands', () {
    test('the identical command run over and over is flagged by its text — two '
        'identical runs with nothing between say the same thing twice', () {
      final guard = AgentLoopGuard();
      const cmd = 'bash build-all.sh';
      for (var i = 0; i < kMaxRunsOfOneCommand - 1; i++) {
        expect(guard.observe(_command(cmd)), isNull);
      }
      expect(guard.observe(_command(cmd)), cmd);
    });

    test('folds case and whitespace so cosmetic drift still counts as one', () {
      final guard = AgentLoopGuard();
      expect(guard.observe(_command('cat  x')), isNull);
      expect(guard.observe(_command('CAT x')), isNull);
      expect(guard.observe(_command('cat x ')), isNull);
      // Same command dressed three different ways plus one more trips the limit.
      expect(guard.observe(_command('cat x')), isNotNull);
    });

    test('a command between two writes resets them both — the debug round of '
        'edit, run, edit, run is the shape of progress, not of a loop', () {
      final guard = AgentLoopGuard();
      String? tripped;
      for (var i = 0; i < 10; i++) {
        tripped ??= guard.observe(
          _edit('/repo/plugins/cache.js', before: 'v$i', after: 'v${i + 1}'),
        );
        tripped ??= guard.observe(_command('node -e "check $i"'));
      }
      expect(tripped, isNull);
    });

    test('clips a long command so the message cannot run on', () {
      final guard = AgentLoopGuard();
      final long = 'python3 -c "${'x' * 200}"';
      String? label;
      for (var i = 0; i < kMaxRunsOfOneCommand; i++) {
        label = guard.observe(_command(long));
      }
      expect(label, isNotNull);
      expect(label!.length, lessThanOrEqualTo(40));
      expect(label, endsWith('…'));
    });
  });

  test('never flags a request with no target to be stuck on', () {
    final guard = AgentLoopGuard();
    // An unrecognised kind, and an edit missing its path, are nothing we can
    // call a loop — counting them would stop a turn over a phantom.
    for (var i = 0; i < kMaxEditsInARow + 2; i++) {
      expect(guard.observe(_other()), isNull);
      expect(guard.observe(_edit('')), isNull);
    }
  });
}
