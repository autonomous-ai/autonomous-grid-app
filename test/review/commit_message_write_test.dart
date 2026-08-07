import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_transport.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/features/review/logic/commit_message_writer.dart';
import 'package:grid_app/features/review/logic/review_file.dart';
import 'package:grid_app/features/review/logic/review_scope.dart';
import 'package:grid_app/features/review/logic/review_snapshot.dart';
import 'package:grid_app/infrastructure/cli/git_providers.dart';
import 'package:grid_app/infrastructure/cli/git_review.dart';

import 'fake_git_runner.dart';

/// A transport that answers with one line, and remembers what it was shown.
class FakeChatTransport implements ChatTransport {
  FakeChatTransport(this.reply);

  final String reply;
  String? sawPatch;

  @override
  Stream<ChatStreamEvent> stream({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async* {
    sawPatch = messages.last['content'] as String;
    yield ChatDelta(reply);
    yield const ChatDone();
  }
}

ReviewSnapshot snapshotWith(List<ReviewFile> files) => ReviewSnapshot(
  root: '/repo',
  branch: 'main',
  scope: const UncommittedChanges(),
  files: files,
);

/// A container with a serving local engine, so the writer has somewhere to ask
/// without a grid or a network.
ProviderContainer containerWith({
  required FakeGitRunner runner,
  required FakeChatTransport transport,
}) {
  final made = ProviderContainer(
    overrides: [
      gitRunnerProvider.overrideWithValue(runner),
      chatTransportProvider.overrideWithValue(transport),
      localProviderEndpointProvider.overrideWithValue('http://127.0.0.1:8080'),
      servingModelProvider.overrideWithValue('qwen'),
    ],
  );
  addTearDown(made.dispose);
  return made;
}

void main() {
  test('a change that is entirely a new file is still described — `git diff` '
      'says nothing about a file Git has never been told about, and the row '
      'answered "nothing to describe" over a list showing +32', () async {
    final runner = FakeGitRunner(
      (args) => switch (args) {
        // What Git really answers here: the new file is in no commit and no
        // index, so there is nothing to diff.
        ['diff', 'HEAD'] => gitSaid(''),
        // `--no-index` reports "these differ" as exit 1. That is the normal
        // answer for every untracked file, not a failure.
        ['diff', '--no-index', ...] => GitRun(
          exitCode: 1,
          stdout: '+++ b/test.md\n+# Notes\n',
          stderr: '',
        ),
        _ => gitSaid(''),
      },
    );
    final transport = FakeChatTransport('Add a notes file');
    final container = containerWith(runner: runner, transport: transport);

    final (message, error) = await container
        .read(commitMessageWriterProvider)
        .write(
          snapshot: snapshotWith(const [
            ReviewFile(path: 'test.md', kind: ReviewFileKind.untracked),
          ]),
          includeUnticked: true,
        );

    expect(error, isNull);
    expect(message, 'Add a notes file');
    expect(transport.sawPatch, contains('# Notes'));
  });

  test('a file left unticked is left out of what the model reads, or the '
      'message would describe a change the commit will not carry', () async {
    final runner = FakeGitRunner(
      (args) => switch (args) {
        ['diff', '--cached'] => gitSaid('+++ b/a.dart\n+final x = 1;\n'),
        _ => gitSaid(''),
      },
    );
    final transport = FakeChatTransport('Add x');
    final container = containerWith(runner: runner, transport: transport);

    await container
        .read(commitMessageWriterProvider)
        .write(
          snapshot: snapshotWith(const [
            ReviewFile(
              path: 'a.dart',
              kind: ReviewFileKind.added,
              staged: true,
            ),
            ReviewFile(path: 'test.md', kind: ReviewFileKind.untracked),
          ]),
          includeUnticked: false,
        );

    expect(transport.sawPatch, contains('final x = 1;'));
    expect(transport.sawPatch, isNot(contains('test.md')));
    expect(runner.ran('diff'), isTrue);
    expect(
      runner.calls.any((args) => args.contains('--no-index')),
      isFalse,
      reason: 'the untracked file is not part of this commit',
    );
  });

  test('nothing ticked and the toggle off says exactly that — never "tick a '
      'file" at someone who already has', () async {
    final runner = FakeGitRunner((args) => gitSaid(''));
    final transport = FakeChatTransport('unused');
    final container = containerWith(runner: runner, transport: transport);

    final (message, error) = await container
        .read(commitMessageWriterProvider)
        .write(
          snapshot: snapshotWith(const [
            ReviewFile(path: 'a.dart', kind: ReviewFileKind.modified),
          ]),
          includeUnticked: false,
        );

    expect(message, isNull);
    expect(error, contains('Nothing is ticked yet'));
  });

  test(
    'no Git on this computer is its own answer, not an empty change',
    () async {
      final runner = FakeGitRunner((args) => null);
      final transport = FakeChatTransport('unused');
      final container = containerWith(runner: runner, transport: transport);

      final (message, error) = await container
          .read(commitMessageWriterProvider)
          .write(snapshot: snapshotWith(const []), includeUnticked: true);

      expect(message, isNull);
      expect(error, contains('could not run Git'));
    },
  );
}
