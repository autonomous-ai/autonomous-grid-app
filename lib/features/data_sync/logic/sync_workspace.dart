import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/grid_paths.dart';
import 'sync_bundle.dart';

/// The only part of Sync & Backup that touches the disk.
///
/// Everything else in this feature is bytes and maps; the reading, the backup,
/// and the careful writing live here so the rules stay testable and the file
/// handling stays in one place. Point it at a temporary directory in tests —
/// never at a real `~/.grid`.
class SyncWorkspace {
  SyncWorkspace({Directory? home, Directory? outputs})
    : _home = home ?? GridPaths.home,
      _outputs = outputs;

  final Directory _home;
  final Directory? _outputs;

  /// How many rollback copies are kept. Enough to undo a merge that went
  /// somewhere unexpected, few enough that a big history doesn't quietly fill
  /// the disk.
  static const int keptBackups = 5;

  Directory get _app => Directory('${_home.path}/app');

  Directory get chatsDir => Directory('${_app.path}/chats');

  Directory get outputsDir => _outputs ?? Directory('${_home.path}/outputs');

  Directory get syncedMediaDir => Directory('${outputsDir.path}/synced');

  File get promptsFile => File('${_app.path}/prompts.json');

  File get projectsFile => File('${_app.path}/projects.json');

  File get markerFile => File('${_app.path}/sync_state.json');

  Directory get backupsDir => Directory('${_app.path}/backups');

  /// Every chat on this machine, keyed by id, as raw maps.
  ///
  /// A file that won't parse is skipped rather than fatal — the same leniency
  /// `ChatStore` gives the sidebar. It also means a corrupt file is never
  /// uploaded and never used to overrule a good copy from the other machine.
  Future<Map<String, Map<String, Object?>>> readChats() async {
    final out = <String, Map<String, Object?>>{};
    if (!chatsDir.existsSync()) return out;
    await for (final entry in chatsDir.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      final parsed = _decodeObject(await _readOrNull(entry));
      if (parsed == null) continue;
      final id = parsed['id'];
      if (id is String && id.isNotEmpty) out[id] = parsed;
    }
    return out;
  }

  /// The saved prompts, or an empty list when the file isn't there yet.
  Future<List<Map<String, Object?>>> readPrompts() =>
      _readObjectList(promptsFile);

  /// The project list, or an empty list when the file isn't there yet.
  Future<List<Map<String, Object?>>> readProjects() =>
      _readObjectList(projectsFile);

  /// Sizes for [paths], with null for anything no longer on this disk — the
  /// shape [planSyncMedia] takes.
  Future<List<SyncMediaCandidate>> statMedia(List<String> paths) async {
    final out = <SyncMediaCandidate>[];
    for (final path in paths) {
      final file = File(path);
      final exists = await file.exists();
      out.add((path: path, bytes: exists ? await file.length() : null));
    }
    return out;
  }

  /// Where a media object from a snapshot lands on this machine.
  ///
  /// Named by object id, not by the name it had elsewhere: two machines can
  /// each have an `image.png`, and the id is the one name that can't collide.
  String localMediaPath(SyncMediaEntry entry) {
    final dot = entry.rel.lastIndexOf('.');
    final slash = entry.rel.lastIndexOf('/');
    final ext = dot > slash && dot != -1 ? entry.rel.substring(dot) : '';
    return '${syncedMediaDir.path}/${entry.oid}$ext';
  }

  /// Reads a media file for upload, or null if it vanished since it was
  /// planned — a chat can reference a file the user deleted a minute ago.
  Future<Uint8List?> readMedia(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// Writes a downloaded media object, skipping the write when it is already
  /// here — the same bytes under the same id, by definition.
  Future<void> writeMedia(SyncMediaEntry entry, List<int> bytes) async {
    final file = File(localMediaPath(entry));
    if (await file.exists()) return;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  /// Zips the app-owned files this merge is about to touch, and returns the
  /// backup. Older backups beyond [keptBackups] are removed.
  ///
  /// Runs before anything is written. If it fails, the merge must not start:
  /// the whole promise of "download is safe" rests on this file existing.
  Future<File> backup(String stamp) async {
    final entries = <String, List<int>>{};
    if (chatsDir.existsSync()) {
      await for (final entry in chatsDir.list()) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final bytes = await _readOrNull(entry);
        if (bytes != null) {
          entries['$syncChatsPrefix${_basename(entry.path)}'] = bytes;
        }
      }
    }
    await _addIfPresent(entries, promptsFile, syncPromptsEntry);
    await _addIfPresent(entries, projectsFile, syncProjectsEntry);
    await backupsDir.create(recursive: true);
    final file = File('${backupsDir.path}/$stamp.zip');
    await file.writeAsBytes(packSyncArchive(entries), flush: true);
    await _pruneBackups();
    return file;
  }

  /// Writes the chats a merge decided to take, one file each.
  Future<void> applyChats(Map<String, Map<String, Object?>> chats) async {
    if (chats.isEmpty) return;
    await chatsDir.create(recursive: true);
    for (final entry in chats.entries) {
      final file = File('${chatsDir.path}/${entry.key}.json');
      await file.writeAsString(_pretty(entry.value), flush: true);
    }
  }

  /// Writes the merged prompt list.
  Future<void> writePrompts(List<Map<String, Object?>> prompts) =>
      _writeJson(promptsFile, prompts);

  /// Writes the merged project list.
  Future<void> writeProjects(List<Map<String, Object?>> projects) =>
      _writeJson(projectsFile, projects);

  /// The snapshot version this machine last pushed or pulled, or null if it
  /// never has.
  Future<int?> readMarker() async {
    final parsed = _decodeObject(await _readOrNull(markerFile));
    final version = parsed?['version'];
    return version is int ? version : null;
  }

  /// Remembers [version] as what this machine is in step with.
  Future<void> writeMarker(int version, DateTime at) async {
    await _app.create(recursive: true);
    await markerFile.writeAsString(
      _pretty({'version': version, 'at': at.toUtc().toIso8601String()}),
      flush: true,
    );
  }

  Future<void> _writeJson(File file, Object? value) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(_pretty(value), flush: true);
  }

  Future<void> _addIfPresent(
    Map<String, List<int>> entries,
    File file,
    String name,
  ) async {
    final bytes = await _readOrNull(file);
    if (bytes != null) entries[name] = bytes;
  }

  Future<void> _pruneBackups() async {
    final files = <File>[
      await for (final entry in backupsDir.list())
        if (entry is File && entry.path.endsWith('.zip')) entry,
    ]..sort((a, b) => b.path.compareTo(a.path));
    for (final file in files.skip(keptBackups)) {
      await file.delete();
    }
  }

  Future<Uint8List?> _readOrNull(File file) async {
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  Future<List<Map<String, Object?>>> _readObjectList(File file) async {
    final bytes = await _readOrNull(file);
    if (bytes == null) return [];
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return [];
    }
    if (decoded is! List) return [];
    return [
      for (final item in decoded)
        if (item is Map<String, Object?>) item,
    ];
  }

  Map<String, Object?>? _decodeObject(Uint8List? bytes) {
    if (bytes == null) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  String _basename(String path) => path.split('/').last;

  String _pretty(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(value);
}
