import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

  /// The newest unwritten snapshot per chat, and the write draining it.
  ///
  /// One entry, not a queue: two commits landing in the same breath are two
  /// versions of the same file, and writing the older one first is work whose
  /// only effect is to be overwritten. The loop in [_drain] picks up whatever
  /// arrived while the last write was in the air.
  final Map<String, Conversation> _queued = {};
  final Map<String, Future<void>> _draining = {};

  /// Every write in flight, from **any** store pointed at this folder.
  ///
  /// Static because the folder is the shared thing, not the object: a second
  /// [ChatStore] built over the same directory — a test reading back what the
  /// app just wrote, a restore reading the folder the chat tab is writing to —
  /// must not read a file mid-write, and it has no way to know about writes it
  /// did not queue. [loadAll] waits on this, which is what makes reading the
  /// folder safe from anywhere.
  static final Set<Future<void>> _inFlight = {};

  /// Chats deleted while a write for them was queued or in flight — the write is
  /// dropped rather than allowed to put the file back.
  final Set<String> _deleted = {};

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
    // Never read the folder out from under a write — see [_inFlight].
    await settled;
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

  /// Write [conversation] to `<id>.json` — off this isolate, and without the
  /// caller waiting.
  ///
  /// **This used to encode and write inline, and it was the app's worst stall.**
  /// A chat is rewritten whole on every commit: the user's turn, the reply
  /// landing, and — in a `/loop` — the loop's own bookkeeping after each
  /// iteration. Measured on a chat a loop had been working in overnight (9 MB,
  /// 110 messages, 7,765 steps):
  ///
  /// ```
  /// encode, pretty-printed   98 ms   ← what this did
  /// encode, compact          92 ms
  /// write, flushed           28 ms
  /// ```
  ///
  /// So each loop iteration spent the better part of half a second with the
  /// window frozen, growing with the chat, and a loop is exactly the feature
  /// that produces chats like that. Now the whole of it — `toJson`, the encode
  /// and the write — happens in a spawned isolate (3 ms of overhead on an
  /// ordinary chat) and the UI thread hands over the object and moves on.
  ///
  /// Fire-and-forget on purpose: every caller is reporting a change that has
  /// already happened in memory, and none of them has anything to do about a
  /// disk that is slow. [settled] is for tests, which do.
  void save(Conversation conversation) {
    final id = conversation.id;
    // A scheduled task's chat keeps one id for the life of the task, so a chat
    // deleted and then delivered into again is a real sequence, not a stale
    // write racing a deletion.
    _deleted.remove(id);
    _queued[id] = conversation;
    _draining[id] ??= _track(_drain(id));
  }

  /// Completes when every queued write has landed — this store's and any other
  /// store's over the same folder (see [_inFlight]).
  ///
  /// [loadAll] awaits it, so reading is safe without anyone remembering to. The
  /// app itself never waits on a write anywhere else, which is the point of the
  /// shape above.
  Future<void> get settled async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }

  /// Remove a conversation's file. No-op when it's already gone.
  ///
  /// Synchronous, unlike [save]: deleting is a few bytes of directory work, and
  /// the caller has just taken the chat off the screen — it must be gone from
  /// disk before anything can read the folder again.
  void delete(String id) {
    _queued.remove(id);
    _deleted.add(id);
    final file = _fileFor(id);
    if (file.existsSync()) file.deleteSync();
  }

  /// Hold [write] in [_inFlight] for as long as it runs, so anything reading
  /// the folder can wait for it.
  Future<void> _track(Future<void> write) async {
    _inFlight.add(write);
    try {
      await write;
    } finally {
      _inFlight.remove(write);
    }
  }

  Future<void> _drain(String id) async {
    try {
      var next = _queued.remove(id);
      while (next != null) {
        if (!_deleted.contains(id)) await _write(next);
        next = _queued.remove(id);
      }
    } finally {
      _draining.remove(id);
    }
  }

  /// One write, entirely in a spawned isolate.
  ///
  /// [path] is resolved out here so the closure captures two plain values — a
  /// String and the conversation. Reaching for `_fileFor` inside it would
  /// capture `this`, and this object holds the futures above, which cannot
  /// cross an isolate boundary at all.
  Future<void> _write(Conversation conversation) async {
    final path = _fileFor(conversation.id).path;
    try {
      await Isolate.run(() {
        final file = File(path);
        file.parent.createSync(recursive: true);
        // Compact, not indented. Nothing reads these by hand — `jq` is right
        // there when something does — and the indent cost 0.7 MB of the 9 MB
        // chat above, which is paid again on every launch, by the decode.
        file.writeAsStringSync(jsonEncode(conversation.toJson()), flush: true);
      });
    } on Object {
      // A disk that is full, a folder that has gone away, a chat deleted from
      // under the write. The conversation is in memory and on screen either
      // way, and there is nothing to tell the user to do about it here.
    }
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
