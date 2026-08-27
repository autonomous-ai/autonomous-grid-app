import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_session_files.dart';
import 'agent_session_id.dart';
import 'agent_session_source.dart';
import 'codex_rollouts.dart';
import 'host_environment.dart';

/// Claude Code: the app names the session, so there is nothing to find.
///
/// `--session-id <uuid>` is accepted only for a session that does not exist yet
/// (measured on 2.1.243: reusing one is refused outright with `Session ID … is
/// already in use`), which is why [mint] is only ever consulted when no id
/// survived [holds] — the caller switches to `--resume` from then on.
///
/// Its [watch] settles null and immediately. That is not a gap: the id is known
/// before the process starts, the caller has already written it down, and an
/// open watcher would be waiting for an answer that cannot change.
class ClaudeSessionSource implements AgentSessionSource {
  const ClaudeSessionSource(this._files);

  final AgentSessionFiles _files;

  @override
  Future<bool> holds(String sessionId) => _files.claudeHolds(sessionId);

  @override
  String? mint() => newAgentSessionId();

  @override
  Future<AgentSessionWatch> watch({
    required String chatId,
    required String workdir,
    required bool resuming,
  }) async => const SettledSessionWatch(null);
}

/// Codex: the id can only be read back off the rollout the CLI writes.
///
/// Nothing can be told to Codex, so [mint] is null and a chat that has no
/// resumable id simply starts a new conversation — one whose name has to be
/// discovered afterwards.
///
/// The rollout is written on the **first turn**, not at start-up, so the watch
/// may be outstanding for as long as it takes the user to type.
class CodexSessionSource implements AgentSessionSource {
  const CodexSessionSource(this._files, this._rollouts);

  final AgentSessionFiles _files;
  final CodexRollouts _rollouts;

  @override
  Future<bool> holds(String sessionId) => _files.codexHolds(sessionId);

  @override
  String? mint() => null;

  @override
  Future<AgentSessionWatch> watch({
    required String chatId,
    required String workdir,
    required bool resuming,
  }) async {
    // A resumed session already has the name it will keep. Codex writes a fresh
    // rollout for it either way, so a watch here would find that file and
    // rename the chat onto a session that is the same conversation under a
    // second id — work for nothing, and a chance to get it wrong.
    if (resuming) return const SettledSessionWatch(null);
    return _CodexWatch(
      rollouts: _rollouts,
      workdir: workdir,
      // Taken now, on this side of the spawn: the new rollout can only be told
      // apart from the ones already here by having looked first.
      before: await _rollouts.snapshot(),
    );
  }
}

class _CodexWatch implements AgentSessionWatch {
  _CodexWatch({
    required CodexRollouts rollouts,
    required this.workdir,
    required this.before,
  }) : _rollouts = rollouts;

  final CodexRollouts _rollouts;
  final String workdir;
  final Set<String> before;

  @override
  Future<String?> settle({
    required bool Function() keepWaiting,
    required Duration deadline,
  }) {
    final until = DateTime.now().add(deadline);
    return _rollouts.discover(
      before: before,
      workdir: workdir,
      // The deadline is folded into liveness rather than added beside it, so
      // `discover` keeps its single stopping condition. Without the clock this
      // ran for the life of the chat: once two rollouts shared a working
      // directory the choice could never be made, and the app went on listing
      // `~/.codex/sessions` every three seconds to be told so again.
      keepWaiting: () => keepWaiting() && DateTime.now().isBefore(until),
    );
  }
}

/// Hermes: discovered once, then **pinned to a name the app chose**.
///
/// `--resume` takes a title as readily as an id, and `hermes sessions rename`
/// can set one. So the first launch discovers whatever id Hermes gave itself and
/// renames it to [_titleFor]; every launch after that resumes by that title and
/// never has to look again. One discovery buys what Claude Code gets for free.
///
/// **The watch runs on every launch, not only the first**, and that is what
/// makes [holds] able to answer true without checking anything. Measured on
/// 0.20.5: `hermes --tui --resume <missing>` does not fail — it prints
/// `· error: session not found` and drops the user at a working prompt in a
/// fresh session. So a title that has gone stale costs one line on screen, and
/// the watch that is already running picks the replacement session up and
/// re-pins the same title to it. The alternative was a `sessions` query before
/// every launch, which is a subprocess and a second of latency spent to avoid a
/// message that repairs itself.
class HermesSessionSource implements AgentSessionSource {
  const HermesSessionSource(this._executable);

  /// The resolved `hermes` binary — the path providers own that, so this stays
  /// a function of its arguments.
  final String _executable;

  /// The title this app gives a chat's Hermes session.
  ///
  /// Prefixed because the store is shared with the user's own terminal sessions,
  /// and a title that reads like something they wrote is one they may rename or
  /// prune without knowing what it was for. Unique by construction: a chat id is
  /// a microsecond timestamp, so two chats cannot ask for the same name.
  static String titleFor(String chatId) => 'grid-$chatId';

  @override
  Future<bool> holds(String sessionId) async => true;

  @override
  String? mint() => null;

  /// Watches on **every** launch, resuming or not — see the class comment. A
  /// resume that missed leaves a title pointing at nothing, and the session
  /// Hermes opened instead is the one this finds and re-pins. Nothing else in
  /// the app would ever notice the title had gone stale.
  @override
  Future<AgentSessionWatch> watch({
    required String chatId,
    required String workdir,
    required bool resuming,
  }) async => _HermesWatch(
    executable: _executable,
    chatId: chatId,
    workdir: workdir,
    resuming: resuming,
    before: await _sessionIds(_executable, workdir),
  );
}

class _HermesWatch implements AgentSessionWatch {
  _HermesWatch({
    required this.executable,
    required this.chatId,
    required this.workdir,
    required this.resuming,
    required this.before,
  });

  final String executable;
  final String chatId;
  final String workdir;
  final bool resuming;
  final Set<String> before;

  /// How often the store is asked. The same cadence Codex's rollout watch uses,
  /// and for the same reason: the answer cannot arrive before the user's first
  /// turn does, so polling faster only costs subprocesses.
  static const _every = Duration(seconds: 3);

  /// How long a *resuming* launch keeps looking.
  ///
  /// A resume that worked creates no new session, so this watch has nothing to
  /// find and would otherwise poll until the full window ran out — six hundred
  /// subprocesses to answer a question that was already settled. It still looks
  /// for a little while, because a resume that *missed* opens a fresh session
  /// instead and re-pinning that one is what keeps the scheme self-healing.
  static const _resumeWindow = Duration(minutes: 2);

  @override
  Future<String?> settle({
    required bool Function() keepWaiting,
    required Duration deadline,
  }) async {
    final window = resuming && _resumeWindow < deadline
        ? _resumeWindow
        : deadline;
    final until = DateTime.now().add(window);
    String? candidate;
    while (keepWaiting() && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(_every);
      if (!keepWaiting()) return null;
      final fresh = (await _sessionIds(executable, workdir)).difference(before);
      if (fresh.length != 1) {
        candidate = null;
        continue;
      }
      final only = fresh.single;
      // The same single session twice running. One poll is not enough: two
      // sessions started seconds apart look like one candidate on the poll
      // between them, and a rename is a write into the user's own store that
      // nothing else in this app would ever undo.
      if (only != candidate) {
        candidate = only;
        continue;
      }
      // Checked once more immediately before the write, because everything above
      // this line was awaited and a rename is the one thing here that changes
      // the user's own store.
      if (!keepWaiting()) return null;
      final title = HermesSessionSource.titleFor(chatId);
      if (!await _rename(executable, only, title)) return null;
      return title;
    }
    return null;
  }
}

/// The ids of the sessions Hermes has recorded for [workdir].
///
/// **`sessions list`, not `sessions export`, and the reason is the whole of why
/// this lane took three attempts to work.** `export`'s filters — `--cwd`,
/// `--after`, `--newer-than`, `--title` — cannot see a session that is still
/// open. Measured on 0.20.5 against a session created ten minutes earlier and
/// still being typed into: unfiltered, `export` returned its rows; with
/// `--after 1h`, with `--newer-than 1h`, or with `--cwd` set to *any* ancestor
/// of its working directory, it returned every other session and none of that
/// one. The filterable columns are evidently written when the session settles.
///
/// Since this watch exists precisely to identify a session while the user is
/// still talking in it, every one of those filters is unusable here — they do
/// not narrow the answer, they remove it. `sessions list` reports live sessions,
/// honours `--workspace`, and takes a `--limit`, which is all this needs.
///
/// The cost is parsing a table meant for a person. It is bounded: the id is the
/// last whitespace-separated token on its row and ids contain no spaces, and
/// every token is checked against the two shapes Hermes actually issues before
/// it is believed — so a header, a rule, or a wrapped title contributes nothing
/// rather than a bad id.
Future<Set<String>> _sessionIds(String executable, String workdir) async {
  final out = await _run(executable, [
    'sessions',
    'list',
    // Enough to cover every session a machine could plausibly open in one
    // workspace while a chat is starting, and small enough that this stays one
    // cheap call every three seconds.
    '--limit',
    '50',
    // Honoured for live sessions, unlike `export --cwd`, and accepted as either
    // a full path or a basename.
    '--workspace',
    workdir,
  ]);
  final ids = <String>{};
  for (final line in const LineSplitter().convert(out)) {
    final tokens = line.trim().split(RegExp(r'\s+'));
    if (tokens.isEmpty) continue;
    final last = tokens.last;
    if (_sessionIdShape.hasMatch(last)) ids.add(last);
  }
  return ids;
}

/// The two id shapes Hermes issues: its own `20260826_172231_db0997` stamp, and
/// a v4 UUID for sessions that arrived from elsewhere.
final RegExp _sessionIdShape = RegExp(
  r'^(?:\d{8}_\d{6}_[0-9a-f]+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$',
);

/// Gives [sessionId] the name this app will resume it by.
///
/// **Not verified, deliberately.** The only channel that can see a live session
/// is `sessions list`, which has no title filter, and reading the title back out
/// of its fixed-width columns would be a second fragile parse to guard against a
/// collision that cannot happen — [HermesSessionSource.titleFor] is built from a
/// microsecond chat id.
///
/// A rename that silently failed costs one launch: `--resume` on a title nothing
/// answers to is not fatal (Hermes prints `· error: session not found` and opens
/// a fresh session), and the watch running on that launch pins the replacement.
/// The scheme repairs itself, which is worth more here than a check that would
/// have to guess at column widths.
Future<bool> _rename(String executable, String sessionId, String title) async {
  await _run(executable, ['sessions', 'rename', sessionId, title]);
  return true;
}

Future<String> _run(String executable, List<String> arguments) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      environment: HostEnvironment.hermesEnvironment(),
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return result.stdout as String;
  } on Object {
    // A store that cannot be read is a session that cannot be named, which the
    // caller already treats as "start fresh next time". Nothing here is worth
    // failing a launch over.
    return '';
  }
}
