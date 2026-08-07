import '../../../infrastructure/logging/app_log.dart';
import 'review_failure.dart';

/// The sentence for [failure], with Git's own words left in the log.
///
/// The pair is the point, and it is why this is one function rather than a
/// convention: humanising is never the only record (§6). A log that repeats the
/// line the user just read diagnoses nothing, and every caller here had the raw
/// text in hand at exactly the moment it decided to throw it away.
///
/// [what] is what was being attempted, for the log line: "push", "stage
/// lib/a.dart".
String explainReviewFailure(
  ReviewFailure failure, {
  required AppLog log,
  required String what,
  String? branch,
  String? remote,
}) {
  switch (failure) {
    case ReviewNoGit():
      log.failure('review', 'no git to $what');
      return 'This computer has no Git for Grid to use yet.';
    case ReviewGitRefused(:final raw):
      log.failure('review', 'could not $what: $raw');
      return friendlyGitFailure(raw, branch: branch, remote: remote);
  }
}

/// Turns what Git printed into a sentence the user can act on.
///
/// Git talks to developers in a terminal: "fatal: could not read Username for
/// 'https://github.com': terminal prompts disabled" is precise and tells a
/// non-technical user nothing — least of all that *this app* is the one that
/// disabled the prompt, and that their way out is a terminal.
///
/// The raw text is never thrown away: the caller logs it through
/// `appLogProvider` alongside this line, because a log that only repeats the
/// sentence the user just read diagnoses nothing (§6).
String friendlyGitFailure(String raw, {String? branch, String? remote}) {
  final text = raw.toLowerCase();
  final where = remote == null ? 'the remote' : '“$remote”';

  if (_says(text, const [
    'could not read username',
    'could not read password',
    'authentication failed',
    'terminal prompts disabled',
    'permission denied (publickey)',
    'host key verification failed',
    'invalid username or token',
  ])) {
    return 'Grid could not sign in to $where for you. Push from Terminal '
        'once — after that the computer remembers, and this button works.';
  }
  if (_says(text, const [
    'please tell me who you are',
    'unable to auto-detect email',
    'empty ident name',
  ])) {
    return 'Git needs a name and an email address before it can record a '
        'commit. Set them once in Terminal:\n'
        'git config --global user.name "Your Name"\n'
        'git config --global user.email "you@example.com"';
  }
  if (_says(text, const ['nothing to commit', 'no changes added to commit'])) {
    return 'Nothing is selected to commit. Tick the files you want included '
        'first.';
  }
  if (_says(text, const [
    'non-fast-forward',
    'updates were rejected',
    'fetch first',
  ])) {
    final name = branch == null ? 'this branch' : '“$branch”';
    return 'Someone else has pushed to $name since you last pulled. Pull '
        'their work in first, then push again.';
  }
  if (_says(text, const ['you have unmerged files', 'unresolved conflict'])) {
    return 'This folder is in the middle of a merge with conflicts still '
        'open. Finish the merge before committing.';
  }
  if (_says(text, const [
    'could not resolve host',
    'connection timed out',
    'network is unreachable',
    'failed to connect',
  ])) {
    return "Couldn't reach $where. Check this computer's internet connection "
        'and try again.';
  }
  if (_says(text, const ['does not appear to be a git repository'])) {
    return 'Git could not find $where. Check the repository still exists and '
        'that you have access to it.';
  }
  if (_says(text, const ['no upstream', 'no configured push destination'])) {
    return 'This branch has never been pushed, and this folder has no remote '
        'to push it to. Add one in Terminal, then try again.';
  }
  if (_says(text, const ['pre-commit hook', 'hook declined', 'hook failed'])) {
    return 'A check this repository runs before every commit refused this '
        'one. Its output is in the log.';
  }

  // Nothing matched: show Git's own first line rather than inventing a reason.
  // A sentence made up here would be a guess the user can't check.
  return _firstLine(raw);
}

/// True when [lowercased] contains any of [needles].
bool _says(String lowercased, List<String> needles) =>
    needles.any(lowercased.contains);

/// Git's first meaningful line, tidied of the `fatal:`/`error:` prefix that
/// reads as shouting, and capped so a wall of output can't fill the screen.
String _firstLine(String raw) {
  final line = raw
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  if (line.isEmpty) return "Git didn't say what went wrong.";
  final tidied = line
      .replaceFirst(
        RegExp('^(fatal|error|warning): ', caseSensitive: false),
        '',
      )
      .trim();
  final sentence = tidied.isEmpty ? line : tidied;
  if (sentence.length <= 200) return _capitalised(sentence);
  return '${_capitalised(sentence.substring(0, 200))}…';
}

String _capitalised(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
