import 'dart:io';

import 'package:grid_app/infrastructure/cli/agent_session_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Directory claudeRoot;
  late Directory codexRoot;
  late AgentSessionFiles files;

  setUp(() {
    root = Directory.systemTemp.createTempSync('agent_sessions');
    claudeRoot = Directory('${root.path}/.claude/projects')
      ..createSync(recursive: true);
    codexRoot = Directory('${root.path}/.codex/sessions')
      ..createSync(recursive: true);
    files = AgentSessionFiles(claudeRoot: claudeRoot, codexRoot: codexRoot);
  });

  tearDown(() => root.deleteSync(recursive: true));

  group(
    'a stored session id is only worth resuming while the agent has it',
    () {
      test('an id Claude Code wrote a session for resumes, whichever project '
          'folder it landed in — the slug is not guessed at', () async {
        final project = Directory(
          '${claudeRoot.path}/-Users-me--grid-app-agent-workspace',
        )..createSync();
        File(
          '${project.path}/11111111-1111-4111-8111-111111111111.jsonl',
        ).writeAsStringSync('{"type":"user"}\n');

        expect(
          await files.claudeHolds('11111111-1111-4111-8111-111111111111'),
          isTrue,
        );
      });

      test('an id from a launch that was never typed into is gone, because '
          'Claude Code writes the session on the first turn and not before — '
          'resuming it dies with "No conversation found"', () async {
        expect(
          await files.claudeHolds('22222222-2222-4222-8222-222222222222'),
          isFalse,
        );
      });

      test("a Codex rollout is named after its session, so the id in the "
          'filename answers for it — nested by date, the way Codex files '
          'them', () async {
        final day = Directory('${codexRoot.path}/2026/08/25')
          ..createSync(recursive: true);
        File(
          '${day.path}/rollout-2026-08-25T10-24-50-'
          '33333333-3333-4333-8333-333333333333.jsonl',
        ).writeAsStringSync('{"type":"session_meta"}\n');

        expect(
          await files.codexHolds('33333333-3333-4333-8333-333333333333'),
          isTrue,
        );
        expect(
          await files.codexHolds('44444444-4444-4444-8444-444444444444'),
          isFalse,
        );
      });

      test('an agent that has never run on this computer has no history to '
          'lose: a missing folder answers no, it does not throw', () async {
        final absent = AgentSessionFiles(
          claudeRoot: Directory('${root.path}/nowhere/projects'),
          codexRoot: Directory('${root.path}/nowhere/sessions'),
        );

        expect(await absent.claudeHolds('any-id'), isFalse);
        expect(await absent.codexHolds('any-id'), isFalse);
      });

      test('an empty id is never resumable — it is what a half-written '
          'conversation file reads as', () async {
        expect(await files.claudeHolds(''), isFalse);
        expect(await files.codexHolds(''), isFalse);
      });
    },
  );
}
