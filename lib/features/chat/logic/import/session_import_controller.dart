import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/agent_resume_point.dart';
import '../../../projects/logic/project.dart';
import '../chat_sessions_controller.dart';
import '../chat_store.dart';
import 'claude_session_parser.dart';
import 'codex_session_parser.dart';
import 'parsed_session.dart';
import 'session_import_ledger.dart';
import 'session_scanner.dart';

/// Where a found session stands with this app.
enum ImportStatus {
  /// Never imported here.
  fresh,

  /// Imported, and the file hasn't changed since.
  imported,

  /// Imported, but the session has been talked in again since — there are
  /// messages here this app hasn't got.
  changed,
}

/// A session as the import screen shows it: what was found on disk, and what
/// the ledger says has already been done with it.
class ImportableSession {
  const ImportableSession({
    required this.session,
    required this.status,
    this.conversationId,
  });

  final DiscoveredSession session;
  final ImportStatus status;

  /// The chat it became, when it has been imported.
  final String? conversationId;

  /// Whether importing this would add or update a chat. An unchanged import is
  /// still allowed — it just has nothing to do, so the screen offers it as a
  /// finished row rather than a button.
  bool get isActionable => status != ImportStatus.imported;
}

/// A sync in flight: which tool, how far through, and how many were skipped.
///
/// Its own state rather than the screen's, because the run outlives the screen.
/// Two hundred sessions take long enough that the user will click away, and a
/// counter held in a widget would restart the moment they came back — or, worse,
/// carry on invisibly with nothing on screen saying the history was still
/// growing.
class ImportProgress {
  const ImportProgress({
    required this.agent,
    required this.done,
    required this.total,
    this.failed = 0,
  });

  final ImportedAgent agent;

  /// How many have been *attempted*, which is what a progress bar measures.
  /// [failed] is the part of that which didn't land.
  final int done;
  final int total;
  final int failed;

  double get fraction => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

/// The sync running now, or null when none is.
final importProgressProvider =
    NotifierProvider<ImportProgressNotifier, ImportProgress?>(
      ImportProgressNotifier.new,
    );

class ImportProgressNotifier extends Notifier<ImportProgress?> {
  @override
  ImportProgress? build() => null;

  bool _cancelled = false;

  /// Whether Stop has been pressed on the run in flight. Read between sessions
  /// by [SessionImportController.syncAll].
  bool get isCancelled => _cancelled;

  void begin({required ImportedAgent agent, required int total}) {
    _cancelled = false;
    state = ImportProgress(agent: agent, done: 0, total: total);
  }

  void advance({required int failed}) {
    final current = state;
    if (current == null) return;
    state = ImportProgress(
      agent: current.agent,
      done: current.done + 1,
      total: current.total,
      failed: failed,
    );
  }

  /// Ask the run to stop after the session it is on.
  ///
  /// Not mid-session: a half-written chat file is worse than one more chat, and
  /// the longest session on this machine takes under a quarter of a second.
  void cancel() => _cancelled = true;

  void finish() {
    _cancelled = false;
    state = null;
  }
}

/// The scanner, overridable so a test or a probe can point it at fixtures
/// instead of at the user's real history.
final sessionScannerProvider = Provider<SessionScanner>(
  (ref) => SessionScanner(),
);

final sessionImportLedgerProvider = Provider<SessionImportLedger>(
  (ref) => SessionImportLedger(),
);

/// The sessions Claude Code and Codex have on this computer, each marked with
/// what this app has already done with it.
///
/// Reading the list is cheap by construction (see [SessionScanner]); the
/// transcripts are only ever read by [SessionImportController.import], for the
/// one session being imported.
final sessionImportProvider =
    AsyncNotifierProvider<SessionImportController, List<ImportableSession>>(
      SessionImportController.new,
    );

class SessionImportController extends AsyncNotifier<List<ImportableSession>> {
  @override
  Future<List<ImportableSession>> build() => _scan();

  /// Re-read the folders. The other tools are running while this screen is
  /// open, so what it lists goes stale as the user reads it.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_scan);
  }

  Future<List<ImportableSession>> _scan() async {
    final found = await ref.read(sessionScannerProvider).scan();
    final ledger = await ref.read(sessionImportLedgerProvider).load();
    // A chat can be deleted after it was imported. The record then describes
    // something that isn't there, and the session has to be offered again — so
    // the ledger is read *against* the chats that actually exist rather than
    // trusted on its own.
    final chats = {
      for (final chat in ref.read(chatSessionsProvider).conversations) chat.id,
    };

    return [
      for (final session in found)
        ImportableSession(
          session: session,
          status: _statusOf(session, ledger, chats),
          conversationId: ledger[_key(session)]?.conversationId,
        ),
    ];
  }

  ImportStatus _statusOf(
    DiscoveredSession session,
    Map<String, ImportRecord> ledger,
    Set<String> chats,
  ) {
    final record = ledger[_key(session)];
    if (record == null) return ImportStatus.fresh;
    if (!chats.contains(record.conversationId)) return ImportStatus.fresh;
    return record.matchesFile(
          size: session.sizeBytes,
          modified: session.updatedAt,
        )
        ? ImportStatus.imported
        : ImportStatus.changed;
  }

  /// Bring [session] in as a chat, and return null — or a line to show the
  /// user when it couldn't be done.
  ///
  /// Failures come back as a message rather than an exception because every
  /// caller is a button, and a button needs something to say (the same contract
  /// the plugins controller uses).
  ///
  /// [linkProject] adds the folder the session ran in to the user's projects
  /// when it isn't one already. It is what makes the chat continuable: the
  /// agent resumes a session *in a folder*, and a chat that belongs to no
  /// project runs in the app's own workspace instead — where the session would
  /// be resumed against files it has never seen.
  Future<String?> import(
    DiscoveredSession session, {
    required bool linkProject,
  }) async {
    final ledger = ref.read(sessionImportLedgerProvider);
    final records = await ledger.load();
    final failure = await _importOne(
      session,
      linkProject: linkProject,
      records: records,
    );
    if (failure != null) return failure;
    await ledger.save(records.values);
    await _settle();
    return null;
  }

  /// Bring over every session of [agent] that has anything to bring.
  ///
  /// Sessions already imported and unchanged are skipped, so running this a
  /// second time costs a directory scan and nothing else — that is what the
  /// ledger is for, and it is what makes this a *sync* rather than a re-import.
  ///
  /// One at a time, deliberately. Each session is a whole file read and parsed
  /// (230 ms for the biggest on this machine), and running them together would
  /// hold every transcript in memory at once for no gain — the work is disk and
  /// CPU bound, not waiting on anything.
  ///
  /// Failures do not stop the run. One unreadable session out of two hundred is
  /// a count in the summary, not a reason to abandon the other hundred and
  /// ninety-nine.
  Future<void> syncAll(ImportedAgent agent, {required bool linkProject}) async {
    final pending = [
      for (final row in state.value ?? const <ImportableSession>[])
        if (row.session.agent == agent && row.isActionable) row.session,
    ];
    final progress = ref.read(importProgressProvider.notifier);
    if (pending.isEmpty) {
      progress.finish();
      return;
    }

    progress.begin(agent: agent, total: pending.length);
    final ledger = ref.read(sessionImportLedgerProvider);
    final records = await ledger.load();
    var failed = 0;
    for (final session in pending) {
      // Stop is a real stop: what has already been imported stays, and the
      // ledger below records exactly that much.
      if (progress.isCancelled) break;
      final failure = await _importOne(
        session,
        linkProject: linkProject,
        records: records,
      );
      if (failure != null) failed++;
      progress.advance(failed: failed);
    }
    await ledger.save(records.values);
    await _settle();
    progress.finish();
  }

  /// One session, written to disk and noted in [records] — with no re-reading
  /// of the chat folder afterwards.
  ///
  /// That last part is the whole reason this is split out. Re-reading the
  /// history and re-scanning the session folders after *every* session turns a
  /// sync of two hundred into two hundred full re-reads of a history that is
  /// growing by one chat each time. The callers do both once, at the end.
  Future<String?> _importOne(
    DiscoveredSession session, {
    required bool linkProject,
    required Map<String, ImportRecord> records,
  }) async {
    final file = File(session.path);
    final String content;
    try {
      content = await file.readAsString();
    } on FileSystemException {
      return "That session's file couldn't be read. It may have been moved "
          'since this list was drawn — refresh and try again.';
    }

    final lines = const LineSplitter().convert(content);
    // Only a name the tool itself chose is worth preferring over one built from
    // the cleaned transcript — see [DiscoveredSession.namedByTool].
    final preferred = session.namedByTool ? session.title : null;
    final parsed = switch (session.agent) {
      ImportedAgent.claude => parseClaudeSession(
        sessionId: session.sessionId,
        lines: lines,
        preferredTitle: preferred,
      ),
      ImportedAgent.codex => parseCodexSession(
        fallbackSessionId: session.sessionId,
        lines: lines,
        preferredTitle: preferred,
      ),
    };
    if (parsed == null) {
      return 'There was no conversation in that session — nothing to import.';
    }

    final projectId = _projectFor(parsed.workdir, link: linkProject);
    final conversation = parsed
        .toConversation(id: conversationIdFor(parsed), projectId: projectId)
        // Where the chat picks the session back up. Written whatever happens to
        // the project link: a folder the user adds *later* makes this chat
        // continuable then, and dropping the point now would mean re-importing
        // to get it back.
        .copyWith(
          resume: parsed.workdir == null
              ? null
              : AgentResumePoint(
                  agent: parsed.agent.id,
                  sessionId: parsed.sessionId,
                  seen: parsed.messages.length,
                  workdir: parsed.workdir,
                ),
        );

    ref.read(chatStoreProvider).save(conversation);
    records[_key(session)] = ImportRecord(
      agent: session.agent.id,
      sessionId: session.sessionId,
      conversationId: conversation.id,
      sourcePath: session.path,
      digest: digestOfText(content),
      sourceSize: session.sizeBytes,
      sourceModified: session.updatedAt,
      importedAt: DateTime.now(),
    );
    return null;
  }

  /// Fold what was imported into the sidebar, and re-mark the list.
  ///
  /// The store is the source of truth and the chat controller re-reads it — the
  /// same path a restored cloud backup takes.
  Future<void> _settle() async {
    await ref.read(chatSessionsProvider.notifier).reloadFromDisk();
    // Re-scanned *without* going through a loading state, unlike [refresh].
    // The list is already on screen and every row on it is still true; blanking
    // it to a spinner for the moment it takes to re-stat the folders would make
    // a finished import look like the screen had been thrown away and rebuilt.
    state = await AsyncValue.guard(_scan);
  }

  /// The project id for a session that ran in [workdir].
  ///
  /// Only ever an *existing* project unless [link] says otherwise: adding a
  /// folder to the user's projects is a visible change to another screen, and
  /// doing it silently for a hundred imported sessions would fill that screen
  /// with folders they never chose.
  String? _projectFor(String? workdir, {required bool link}) {
    if (workdir == null || workdir.isEmpty) return null;
    final existing = ref
        .read(projectsProvider)
        .where((project) => project.path == workdir)
        .firstOrNull;
    if (existing != null) return existing.id;
    if (!link) return null;
    // A folder that has since been deleted or renamed can't be a project — and
    // a project pointing nowhere is a chat whose agent starts in a folder that
    // isn't there.
    if (!Directory(workdir).existsSync()) return null;
    return ref.read(projectsProvider.notifier).create(path: workdir).id;
  }

  static String _key(DiscoveredSession session) =>
      ledgerKey(session.agent.id, session.sessionId);
}
