import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import 'conversation.dart';

/// Persists Chat conversations as one JSON file per conversation under
/// `~/.grid/app/chats/`. App-owned storage (the CLI never touches it), kept
/// lenient like [GridHomeStore]: a single corrupt file is skipped, never fatal.
///
/// The directory is overridable so tests point at a temp dir and never touch a
/// real grid home.
class ChatStore {
  ChatStore({Directory? directory}) : _dir = directory ?? GridPaths.chatsDir;

  final Directory _dir;

  /// Every saved conversation, newest activity first. Unreadable files are
  /// skipped so one bad file can't hide the rest of the history.
  ///
  /// Asynchronous, and one file at a time, because this reads the *whole*
  /// history: measured at 28 ms over 57 chats (396 KB) on a cold cache, and it
  /// grows with every chat the user keeps. Read synchronously — as it was, from
  /// inside a provider's `build()` — that is the first frame's budget spent
  /// before anything is drawn. Awaiting each file hands the frame back between
  /// them, so a long history costs many short gaps instead of one long freeze.
  Future<List<Conversation>> loadAll() async {
    final out = <Conversation>[];
    try {
      await for (final entry in _dir.list()) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final parsed = await _read(entry);
        if (parsed != null) out.add(parsed);
      }
    } on FileSystemException {
      // No chats folder yet (nothing has been saved), or it went away while
      // being read. Keep whatever was already read: the same leniency a corrupt
      // file gets, and the only alternative is turning a read into a crash the
      // user can do nothing about.
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// Write [conversation] to `<id>.json`, creating the directory on first use.
  void save(Conversation conversation) {
    _dir.createSync(recursive: true);
    _fileFor(conversation.id).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(conversation.toJson()),
      flush: true,
    );
  }

  /// Remove a conversation's file. No-op when it's already gone.
  void delete(String id) {
    final file = _fileFor(id);
    if (file.existsSync()) file.deleteSync();
  }

  File _fileFor(String id) => File('${_dir.path}/$id.json');

  Future<Conversation?> _read(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return Conversation.fromJson(decoded);
    } on Object {
      // Corrupt or hand-broken file — skip it rather than brick the history.
      return null;
    }
  }
}

/// The chat store, overridden in tests with a temp-dir-backed instance.
final chatStoreProvider = Provider<ChatStore>((ref) => ChatStore());
