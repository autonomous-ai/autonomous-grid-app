import '../../../infrastructure/cli/agent_event.dart';

/// How many times **in a row** the assistant may redo the very same thing —
/// write one file, or run one command — before it's treated as stuck.
///
/// Consecutive, not cumulative: a run of four identical steps with no other work
/// between them is a loop; touching one file four times *across* a productive
/// turn is not. Seen live both ways — a weak model rewrote one `schema.prisma`
/// six times back-to-back (a real loop, caught here), while a capable one edited
/// `app.js` four times spread over a 23-step swagger integration (progress, not
/// a loop — every other file between them resets the count).
const int kMaxRepeatsPerTarget = 4;

/// Watches for the assistant getting stuck redoing one step over and over, so a
/// run that spins on a single target is caught and stopped instead of dragging
/// on.
///
/// Pure and turn-scoped — one per turn, fed every edit/command as it arrives. It
/// tracks the current run of the **same** target (an edit's path, or a command's
/// text, case- and whitespace-folded) and reports it once that run reaches
/// [kMaxRepeatsPerTarget]; any different target resets the run, because real
/// progress broke the loop. Requests with no target to name — an unrecognised
/// kind, or an edit/command missing its path/line — pass through untouched:
/// there's nothing there to be stuck on, and they neither count nor reset.
class AgentLoopGuard {
  String? _lastKey;
  int _run = 0;

  /// Record [request]; return a short label for what it's stuck on when this
  /// makes a run of [kMaxRepeatsPerTarget] identical steps, else null.
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
    return _run >= kMaxRepeatsPerTarget ? _labelOf(request) : null;
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
