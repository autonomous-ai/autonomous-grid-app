import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_loop_guard.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

AgentPermission _edit(String path) => AgentPermission(
  id: path,
  kind: AgentPermissionKind.edit,
  summary: 'edit',
  path: path,
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
  group('AgentLoopGuard', () {
    test('lets a file be written up to the limit, then flags the repeat', () {
      final guard = AgentLoopGuard();
      const path = '/repo/prisma/schema.prisma';
      // The first three passes are still plausibly progress — a write and two
      // corrections — so nobody is interrupted for them.
      for (var i = 0; i < kMaxRepeatsPerTarget - 1; i++) {
        expect(guard.observe(_edit(path)), isNull);
      }
      // The fourth pass at the identical file is the loop the user actually hit
      // (schema.prisma nine times); it's flagged with the file's base name.
      expect(guard.observe(_edit(path)), 'schema.prisma');
    });

    test('counts each target separately — real progress is never stopped', () {
      final guard = AgentLoopGuard();
      // A genuine build touches many different files a few times each; no single
      // target reaches the limit, so the turn runs to completion.
      for (final path in ['/a.js', '/b.js', '/c.js', '/.env']) {
        expect(guard.observe(_edit(path)), isNull);
        expect(guard.observe(_edit(path)), isNull);
        expect(guard.observe(_edit(path)), isNull);
      }
    });

    test(
      'a file touched several times across a productive turn is not a loop',
      () {
        final guard = AgentLoopGuard();
        // The swagger integration that a cumulative count wrongly killed: app.js
        // edited four times over a 23-step turn, but never four in a row — every
        // other file between the touches resets the run, so genuine progress is
        // never mistaken for spinning.
        const seq = [
          'app.js',
          'app.js',
          'routes/root.js',
          'plugins/swagger.js',
          'routes/v1/users.js',
          'app.js',
          'routes/api/v1.js',
          'app.js',
        ];
        String? tripped;
        for (final name in seq) {
          tripped ??= guard.observe(_edit('/repo/$name'));
        }
        expect(tripped, isNull);
      },
    );

    test('flags a repeated command by its clipped text', () {
      final guard = AgentLoopGuard();
      const cmd = 'bash build-all.sh';
      for (var i = 0; i < kMaxRepeatsPerTarget - 1; i++) {
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

    test('never flags a request with no target to be stuck on', () {
      final guard = AgentLoopGuard();
      // An unrecognised kind, and an edit missing its path, are nothing we can
      // call a loop — counting them would stop a turn over a phantom.
      for (var i = 0; i < kMaxRepeatsPerTarget + 2; i++) {
        expect(guard.observe(_other()), isNull);
        expect(guard.observe(_edit('')), isNull);
      }
    });

    test('clips a long command so the message cannot run on', () {
      final guard = AgentLoopGuard();
      final long = 'python3 -c "${'x' * 200}"';
      String? label;
      for (var i = 0; i < kMaxRepeatsPerTarget; i++) {
        label = guard.observe(_command(long));
      }
      expect(label, isNotNull);
      expect(label!.length, lessThanOrEqualTo(40));
      expect(label, endsWith('…'));
    });
  });
}
