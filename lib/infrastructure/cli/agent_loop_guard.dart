import 'agent_event.dart';

/// How many times in a row the assistant may write the same file while each
/// write still *says something new*, before it's treated as stuck.
///
/// Deliberately loose. A local model works a file in small hunks — add the
/// helper, fix the regex, adjust the caller — where a stronger one lands the
/// same change in a single write; counting those hunks as repeats stopped a turn
/// at 40 of 42 tests passing, mid-fix. What separates a loop from small steps is
/// not how many writes there are but whether they *go anywhere* — see
/// [kMaxRewindsPerFile], which is the check that catches a real circle early.
const int kMaxEditsInARow = 8;

/// How many times the assistant may put a file back to contents it has already
/// produced — or that were there before it started — before it's treated as
/// stuck.
///
/// Reverting once is ordinary debugging: try it, measure, put it back. Doing it
/// twice is a circle, and no amount of waiting gets out of one.
///
/// A request carrying no contents to compare (an edit whose diff the agent
/// didn't send) reads every repeat as a rewind. That's the old count-the-path
/// rule, which is the safest reading when there's nothing to tell two writes
/// apart.
const int kMaxRewindsPerFile = 2;

/// How many times in a row the assistant may run the *identical* command before
/// it's treated as stuck. Nothing changed between two identical runs, so the
/// second says exactly what the first did — there is no version of this that is
/// progress.
const int kMaxRunsOfOneCommand = 4;

/// Watches for the assistant getting stuck redoing one step over and over, so a
/// run that spins on a single target is caught and stopped instead of dragging
/// on.
///
/// Pure and turn-scoped — one per turn, fed every edit/command *before* it is
/// answered, so the step that trips it can be refused rather than approved and
/// then torn out from under the agent mid-write.
///
/// Two things count as stuck, and the difference is the whole point:
/// * **A rewind** — a file written back to contents already seen. The assistant
///   is circling between versions, and that is caught quickly
///   ([kMaxRewindsPerFile]).
/// * **Churn** — the same target over and over, each time saying something new.
///   Ordinary small-step work looks exactly like this, so the bar is high
///   ([kMaxEditsInARow], [kMaxRunsOfOneCommand]) and any different target in
///   between resets the run.
///
/// Requests with no target to name — an unrecognised kind, or an edit/command
/// missing its path/line — pass through untouched: there's nothing there to be
/// stuck on, and they neither count nor reset.
class AgentLoopGuard {
  String? _lastKey;
  int _run = 0;

  /// Every version of a file seen so far: what was there when the assistant
  /// first touched it, plus everything it has written since. Held as hashes —
  /// this only ever answers "seen this one before?", and a turn can write a lot
  /// of text.
  final Map<String, Set<int>> _versions = {};

  /// How many times each file has been put back to a version already seen.
  final Map<String, int> _rewinds = {};

  /// Record [request]; return a short label for what it's stuck on when this is
  /// the step that makes it a loop, else null.
  String? observe(AgentPermission request) {
    final target = _targetOf(request);
    if (target.isEmpty) return null;
    final key = target.toLowerCase();
    if (key == _lastKey) {
      _run++;
    } else {
      _lastKey = key;
      _run = 1;
    }

    if (request.kind == AgentPermissionKind.command) {
      return _run >= kMaxRunsOfOneCommand ? _labelOf(request) : null;
    }

    final seen = _versions.putIfAbsent(key, () {
      final before = request.oldText;
      return before == null ? <int>{} : <int>{before.hashCode};
    });
    // `add` answers false when the file has already held these contents: this
    // write undoes rather than advances.
    if (!seen.add((request.newText ?? '').hashCode)) {
      final rewinds = (_rewinds[key] ?? 0) + 1;
      _rewinds[key] = rewinds;
      if (rewinds >= kMaxRewindsPerFile) return _labelOf(request);
    }

    return _run >= kMaxEditsInARow ? _labelOf(request) : null;
  }
}

/// What a request is counted by: the file it writes, or the command it runs,
/// with runs of whitespace folded so `cat  x` and `cat x` count as one. Empty
/// for anything else — an unknown kind isn't a target we can call a loop.
String _targetOf(AgentPermission request) => switch (request.kind) {
  AgentPermissionKind.edit => _fold(request.path),
  AgentPermissionKind.command => _fold(request.command),
  AgentPermissionKind.other => '',
};

String _fold(String? raw) => (raw ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');

/// A short human name for the stuck target: a file's base name, or a command
/// clipped so the message doesn't run on. Never the whole path or command line.
String _labelOf(AgentPermission request) => switch (request.kind) {
  AgentPermissionKind.edit => _basename(request.path ?? ''),
  AgentPermissionKind.command => _clip(request.command ?? ''),
  AgentPermissionKind.other => '',
};

String _basename(String path) {
  final trimmed = path.trim();
  final slash = trimmed.lastIndexOf('/');
  return slash == -1 ? trimmed : trimmed.substring(slash + 1);
}

String _clip(String command) {
  final oneLine = command.trim().replaceAll(RegExp(r'\s+'), ' ');
  return oneLine.length <= 40 ? oneLine : '${oneLine.substring(0, 39)}…';
}
