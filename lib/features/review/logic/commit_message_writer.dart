import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/cli/git_providers.dart';
import '../../playground/logic/chat_transport.dart';
import '../../playground/logic/one_shot_target.dart';
import 'review_argv.dart';

/// Writes the commit message from the change itself, so the box doesn't have to
/// start empty.
///
/// One blocking `chat/completions` call through the shared [ChatTransport] —
/// the same path the skill generator takes, at the same target
/// ([resolveOneShotTarget]): the local engine when one is serving, else the
/// grid's relay.
///
/// It only ever *offers* text. The message lands in the box for the user to
/// read and change, and nothing is committed until they press the row that
/// commits — a model's summary of a diff is a draft, not a record.
class CommitMessageWriter {
  const CommitMessageWriter(this._ref);

  final Ref _ref;

  /// How much of the patch the model is shown.
  ///
  /// A whole branch's diff would blow the context window of a small local model
  /// and cost real money on a hosted one, for a summary that is decided by the
  /// first few files anyway. What is cut is *said* — see [_trim].
  static const int _maxPatchChars = 12000;

  /// Draft a message for what a commit in [root] would carry. Exactly one half
  /// of the pair is non-null.
  Future<(String? message, String? error)> write({
    required String root,
    required bool includeUnticked,
    required bool hasCommits,
  }) async {
    final patch = await _ref
        .read(gitRunnerProvider)
        .run(
          root,
          commitDiffArgv(
            includeUnticked: includeUnticked,
            hasCommits: hasCommits,
          ),
        );
    if (patch == null) {
      return (null, 'Grid could not run Git to read the change.');
    }
    if (!patch.ok || patch.stdout.trim().isEmpty) {
      return (
        null,
        'There is nothing to describe yet — tick a file, or turn on '
            '"Include the files not ticked".',
      );
    }

    final target = resolveOneShotTarget(_ref);
    if (target == null) return (null, noModelReady('write the message'));

    final messages = _promptFor(_trim(patch.stdout));
    final log = _ref.read(commandLogProvider.notifier);
    final id = log.begin(
      CliCallKind.http,
      'POST ${target.endpoint}',
      detail: CommandDetail.json(
        chatCompletionsPayload(model: target.model, messages: messages),
        authorized: target.apiKey.isNotEmpty,
      ),
    );
    final (reply, failure) = await _ref
        .read(chatTransportProvider)
        .complete(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
          messages: messages,
        );
    log.finish(
      id,
      exitCode: failure?.statusCode ?? 200,
      error: failure?.message,
      responseBody: reply,
    );

    if (failure != null) {
      return (null, friendlyOneShotError(failure, what: 'write the message'));
    }
    final written = tidyCommitMessage(reply ?? '');
    if (written.isEmpty) {
      return (
        null,
        "The model didn't answer with a message. Try again, or write it "
            'yourself.',
      );
    }
    return (written, null);
  }

  /// The patch as far as the model gets to read it, with the cut named rather
  /// than silently applied (§9).
  String _trim(String patch) {
    if (patch.length <= _maxPatchChars) return patch;
    return '${patch.substring(0, _maxPatchChars)}\n'
        '[… the rest of this change is not shown]';
  }

  static List<Map<String, dynamic>> _promptFor(String patch) => [
    {
      'role': 'system',
      'content':
          'You write Git commit messages. Read the diff and reply with ONLY '
          'the message — no code fence, no quotes, no preamble.\n'
          '- First line: imperative mood, under 72 characters, no full stop. '
          'Say what the change does, not which files moved.\n'
          '- Then, only if the change is not obvious from that line: a blank '
          'line and one or two short sentences on why.\n'
          'Plain language. Never invent a reason the diff does not show.',
    },
    {'role': 'user', 'content': patch},
  ];
}

/// Wire the writer through the container so the panel stays testable — a fake
/// transport swaps in without a live model.
final commitMessageWriterProvider = Provider<CommitMessageWriter>(
  (ref) => CommitMessageWriter(ref),
);

/// Takes what the model said back to a commit message.
///
/// Forgiving on purpose, and pure so it can be tested against the shapes models
/// actually return: a fence around the whole thing, a "Commit message:" lead-in,
/// the subject in quotes, a trailing full stop that the first line of a commit
/// does not take.
String tidyCommitMessage(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';

  text = _unfence(text);
  final lead = RegExp(
    r'^(commit\s+message|message)\s*[:\-]\s*',
    caseSensitive: false,
  );
  text = text.replaceFirst(lead, '').trim();

  final lines = text.split('\n');
  var subject = lines.first.trim();
  // A model that wrapped the subject in quotes wrapped only the subject; the
  // body below it is prose and its quotation marks belong to the sentence.
  subject = _unquote(subject);
  while (subject.endsWith('.')) {
    subject = subject.substring(0, subject.length - 1).trimRight();
  }
  if (subject.isEmpty) return '';

  final body = lines.skip(1).join('\n').trim();
  return body.isEmpty ? subject : '$subject\n\n$body';
}

/// Drops a ``` fence around the whole answer, whatever it was labelled.
String _unfence(String text) {
  if (!text.startsWith('```')) return text;
  final firstBreak = text.indexOf('\n');
  if (firstBreak == -1) return text;
  final end = text.lastIndexOf('```');
  final inner = end > firstBreak
      ? text.substring(firstBreak + 1, end)
      : text.substring(firstBreak + 1);
  return inner.trim();
}

String _unquote(String line) {
  const pairs = [('"', '"'), ('“', '”'), ("'", "'"), ('`', '`')];
  for (final (open, close) in pairs) {
    if (line.length > 1 && line.startsWith(open) && line.endsWith(close)) {
      return line.substring(1, line.length - 1).trim();
    }
  }
  return line;
}
