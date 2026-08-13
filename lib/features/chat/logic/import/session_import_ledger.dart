import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../../../core/grid_paths.dart';
import 'parsed_session.dart';

/// How the importer renders a transcript, as a number that goes up.
///
/// A record made by an older importer describes a chat built by rules this
/// build has since improved on — and the chat is *already there*, unchanged on
/// disk, so nothing else would ever offer to rebuild it. Without this, the day
/// tool steps stopped being a wall of quoted lines and became one block of
/// monospace, every chat imported before that day kept the wall forever.
///
/// Bump it whenever the shape of an imported transcript changes.
const int kImportFormatVersion = 2;

/// One session this machine has already imported.
///
/// The point of writing these down is that importing is not a one-off: a
/// session in Claude Code or Codex goes on growing after it has been imported,
/// and the user will come back for the rest of it. Without a record, the screen
/// can only offer the same hundred sessions again with no idea which are
/// already chats — and a second import would be a duplicate chat, not an
/// update.
class ImportRecord {
  const ImportRecord({
    required this.agent,
    required this.sessionId,
    required this.conversationId,
    required this.sourcePath,
    required this.digest,
    required this.sourceSize,
    required this.sourceModified,
    required this.importedAt,
    this.formatVersion = 0,
  });

  /// The [ImportedAgent.id] that wrote the session.
  final String agent;
  final String sessionId;

  /// The chat this became, so a record can be dropped when its chat is deleted
  /// — otherwise deleting an imported chat would leave it un-importable.
  final String conversationId;

  final String sourcePath;

  /// sha256 of the file as it was imported.
  ///
  /// Computed once, at import, never during a scan: hashing every session on
  /// this machine would mean reading a few hundred megabytes to draw a list.
  /// It earns its keep afterwards — Codex *moves* finished sessions into
  /// `archived_sessions/`, so the same transcript reappears at a new path, and
  /// the digest is what says it is the same one.
  final String digest;

  /// The file's size and modification time when it was imported — the two facts
  /// a scan already has from `stat`, and so the only ones a scan can compare
  /// against to say whether a session has moved on since.
  final int sourceSize;
  final DateTime sourceModified;

  final DateTime importedAt;

  /// The [kImportFormatVersion] in force when this was imported. Zero for a
  /// record written before the field existed, which is older than anything.
  final int formatVersion;

  /// Whether the chat this made was built by the importer this build ships.
  bool get isCurrentFormat => formatVersion >= kImportFormatVersion;

  /// The key both sides of the ledger agree on. Not the path: Codex moves its
  /// files, and a moved session is the same session.
  String get key => ledgerKey(agent, sessionId);

  /// Whether the file at [size]/[modified] is the one this record was made
  /// from.
  ///
  /// Two cheap facts rather than a hash, and deliberately conservative in the
  /// direction that costs nothing: a file that looks changed but isn't offers a
  /// re-import the user can ignore, while a file that looks unchanged and isn't
  /// hides messages they came here to fetch.
  bool matchesFile({required int size, required DateTime modified}) =>
      size == sourceSize &&
      modified.millisecondsSinceEpoch == sourceModified.millisecondsSinceEpoch;

  Map<String, Object?> toJson() => {
    'agent': agent,
    'sessionId': sessionId,
    'conversationId': conversationId,
    'sourcePath': sourcePath,
    'digest': digest,
    'sourceSize': sourceSize,
    'sourceModified': sourceModified.toUtc().toIso8601String(),
    'importedAt': importedAt.toUtc().toIso8601String(),
    'formatVersion': formatVersion,
  };

  static ImportRecord? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final agent = raw['agent'];
    final sessionId = raw['sessionId'];
    final conversationId = raw['conversationId'];
    if (agent is! String || agent.isEmpty) return null;
    if (sessionId is! String || sessionId.isEmpty) return null;
    if (conversationId is! String || conversationId.isEmpty) return null;
    final modified = DateTime.tryParse('${raw['sourceModified']}');
    final imported = DateTime.tryParse('${raw['importedAt']}');
    if (modified == null || imported == null) return null;
    return ImportRecord(
      agent: agent,
      sessionId: sessionId,
      conversationId: conversationId,
      sourcePath: raw['sourcePath'] is String
          ? raw['sourcePath'] as String
          : '',
      digest: raw['digest'] is String ? raw['digest'] as String : '',
      sourceSize: raw['sourceSize'] is num
          ? (raw['sourceSize'] as num).toInt()
          : 0,
      sourceModified: modified.toLocal(),
      importedAt: imported.toLocal(),
      formatVersion: raw['formatVersion'] is num
          ? (raw['formatVersion'] as num).toInt()
          : 0,
    );
  }
}

/// How a record is filed: by the agent and its own session id.
String ledgerKey(String agent, String sessionId) => '$agent|$sessionId';

/// The record of what has been imported, at `~/.grid/app/imported_sessions.json`.
///
/// App-owned, like everything else under `app/` — and named after what it holds
/// rather than after the screen that reads it, since a later "import from X"
/// belongs in the same file.
///
/// Modelled on the ledger Codex keeps for the same job
/// (`~/.codex/external_agent_session_imports.json`): key by source, remember a
/// digest, and never import the same bytes twice.
class SessionImportLedger {
  SessionImportLedger({File? file})
    : _file = file ?? File('${GridPaths.home.path}/app/imported_sessions.json');

  final File _file;

  /// Every record, by [ledgerKey].
  ///
  /// A missing or unreadable file reads as "nothing imported yet". That is the
  /// recoverable answer: the user is offered sessions they already have, which
  /// is a duplicate they can delete — where the opposite mistake would hide
  /// their history behind a file they can't see and wouldn't think to delete.
  Future<Map<String, ImportRecord>> load() async {
    try {
      if (!await _file.exists()) return {};
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map<String, dynamic>) return {};
      final records = decoded['records'];
      if (records is! List) return {};
      final out = <String, ImportRecord>{};
      for (final raw in records) {
        final record = ImportRecord.fromJson(raw);
        if (record != null) out[record.key] = record;
      }
      return out;
    } on Object {
      return {};
    }
  }

  /// Write [records] back, replacing the file.
  Future<void> save(Iterable<ImportRecord> records) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'records': [for (final record in records) record.toJson()],
      }),
      flush: true,
    );
  }
}

/// sha256 of a session file's contents.
///
/// Takes the text rather than the file because the import has just read it to
/// parse it. Hashing the path instead would read a 5 MB session twice for one
/// import, and — worse — hash a *different* read than the one that produced the
/// transcript, so a session appended to between the two would be filed under a
/// digest matching neither.
String digestOfText(String content) =>
    sha256.convert(utf8.encode(content)).toString();
