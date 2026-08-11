import '../../../infrastructure/cli/grid_cli_service.dart';

/// A failure worth showing, already turned into something a person can act on.
///
/// [raw] is kept beside it because humanizing must never be the only record:
/// the CLI's own words go to the command log, and a log that repeats the
/// sentence the user just read diagnoses nothing.
class CodeGridException implements Exception {
  const CodeGridException(this.message, {this.raw});

  final String message;
  final String? raw;

  @override
  String toString() => message;
}

/// This build of the `grid` tool has no `project`/`task` commands at all.
///
/// Its own words are argparse's, and they are unusable — a list of every
/// command it *does* have, with the missing one nowhere in it. So this is
/// detected rather than shown, and the screen offers an update instead of an
/// error.
class CodeCliTooOld implements Exception {
  const CodeCliTooOld();

  @override
  String toString() => 'This computer\'s grid tool has no shared projects yet.';
}

/// Whether [result] failed because the CLI does not know the command.
///
/// argparse answers an unknown subcommand with `invalid choice: 'task'` and
/// exit 2, so the two words are matched together — a task whose *prompt*
/// contains that phrase must not be read as a missing command.
bool cliLacksCodeCommands(CliResult result) {
  if (result.ok) return false;
  final message = result.errorMessage.toLowerCase();
  if (!message.contains('invalid choice')) return false;
  return message.contains("'task'") || message.contains("'project'");
}

/// The sentence to show for a failed command.
///
/// Most of the CLI's own refusals are already the right thing to print: they
/// name what happened and what to do about it ("Behind main, so a promote would
/// be refused", "it is a symlink, and uploading what it points at would send a
/// file you did not name"). Rewriting those would lose detail and drift.
///
/// So this maps only the ones whose wording assumes a terminal — a sign-in
/// prompt the app answers differently, and a bare transport failure — and
/// otherwise passes the CLI through, bounded so one runaway line cannot take
/// over a dialog.
String friendlyCodeError(CliResult result) {
  if (result.sessionExpired) {
    return 'Your grid session expired — sign in again to keep working.';
  }
  final raw = result.errorMessage.trim();
  if (raw.isEmpty) {
    return "Couldn't reach the grid. Check your connection and try again.";
  }
  final lower = raw.toLowerCase();
  if (lower.startsWith('cannot reach the relay')) {
    return "Couldn't reach this grid's server. It may be offline — try again "
        'in a moment.';
  }
  if (lower.contains('grid command timed out')) {
    return 'The grid tool stopped responding. Try again.';
  }
  return _bounded(raw);
}

/// How much of a CLI message a dialog will show. Past this it stops being a
/// sentence and starts being a wall — the whole thing is in the command log.
const int _messageLimit = 400;

String _bounded(String message) => message.length <= _messageLimit
    ? message
    : '${message.substring(0, _messageLimit - 1)}…';
