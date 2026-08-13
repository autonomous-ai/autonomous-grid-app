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

  /// Bring [session] in as a chat, and return null — or a line to show the user
  /// when it couldn't be done.
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
    await _remember(session, conversation.id, digestOfText(content));
    // Fold the new chat into the sidebar. The store is the source of truth and
    // the controller re-reads it — the same path a restored cloud backup takes.
    await ref.read(chatSessionsProvider.notifier).reloadFromDisk();
    await refresh();
    return null;
  }

  /// Note that [session] is now [conversationId], keeping every other record.
  Future<void> _remember(
    DiscoveredSession session,
    String conversationId,
    String digest,
  ) async {
    final ledger = ref.read(sessionImportLedgerProvider);
    final records = await ledger.load();
    records[_key(session)] = ImportRecord(
      agent: session.agent.id,
      sessionId: session.sessionId,
      conversationId: conversationId,
      sourcePath: session.path,
      digest: digest,
      sourceSize: session.sizeBytes,
      sourceModified: session.updatedAt,
      importedAt: DateTime.now(),
    );
    await ledger.save(records.values);
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
