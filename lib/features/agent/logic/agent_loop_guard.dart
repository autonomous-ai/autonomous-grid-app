import '../../../infrastructure/cli/agent_event.dart';

/// How many times the assistant may ask to redo the very same thing — write one
/// file, or run one command — in a single turn before it's treated as stuck.
///
/// A capable model writes a file once, twice if it corrects itself; a fourth go
/// at the identical target is a loop, not progress. Seen live: a weak `auto`
/// model rewrote one `schema.prisma` nine times across 42 minutes, asking the
/// user to approve each one, and never finishing. Stopping at the fourth turns
/// that spin into a clear "it's stuck" instead of an open-ended wait.
const int kMaxRepeatsPerTarget = 4;

/// A per-turn tally of what the assistant has asked to do, so a run that keeps
/// redoing the same step is caught and stopped instead of spinning.
///
/// Pure and turn-scoped — one per turn, fed every edit/command as it arrives. It
/// counts by target (an edit's path, or a command's text, case- and
/// whitespace-folded) and reports the first target to reach
/// [kMaxRepeatsPerTarget]. Requests with no target to name — an unrecognised
/// kind, or an edit/command missing its path/line — are never counted: there's
/// nothing there to be stuck on.
class AgentLoopGuard {
  final Map<String, int> _seen = {};

  /// Record [request]; return a short label for what it's stuck on when this is
  /// the request that reaches [kMaxRepeatsPerTarget], else null.
  String? observe(AgentPermission request) {
    final target = _targetOf(request);
    if (target.isEmpty) return null;
    final key = target.toLowerCase();
    final count = (_seen[key] ?? 0) + 1;
    _seen[key] = count;
    return count >= kMaxRepeatsPerTarget ? _labelOf(request) : null;
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
