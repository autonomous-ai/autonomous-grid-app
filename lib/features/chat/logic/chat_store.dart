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
/// Beside them sits [kChatIndexName] — every conversation's *header* and none of
/// its messages, so the sidebar can be drawn without reading the transcripts.
/// See [loadIndex].
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

  /// Every known conversation's header, keyed by id — what [kChatIndexName]
  /// holds. Seeded by [loadAll] and kept up to date by [save] and [delete].
  final Map<String, Conversation> _index = {};

  /// The index has moved since it was last written out.
  bool _indexDirty = false;

  /// The write draining [_indexDirty], or null when none is running. One at a
  /// time and coalescing, exactly like [_draining]: a `/loop` saves the same
  /// chat many times a second and every one of those moves its `updatedAt`, so
  /// without this the index would be rewritten once per turn to say something
  /// the next turn immediately supersedes.
  Future<void>? _indexDraining;

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
    var whole = true;
    try {
      await for (final entry in _dir.list()) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        if (entry.uri.pathSegments.last == kChatIndexName) continue;
        final parsed = await _read(entry);
        if (parsed != null) out.add(parsed);
      }
    } on FileSystemException {
      // No chats folder yet (nothing has been saved), or it went away while
      // being read. Keep whatever was already read: the same leniency a corrupt
      // file gets, and the only alternative is turning a read into a crash the
      // user can do nothing about.
      whole = false;
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    // The folder is the truth and this just read all of it, so this is also the
    // one moment the index can be *healed*: a chat restored from a backup, one
    // deleted by hand, or anything a build that predates the index left behind.
    //
    // Only when the read got all the way through, though. A folder that went
    // away mid-listing leaves a partial answer, and writing that out would
    // recreate the folder to put a half-index in it — an index claiming the
    // history is smaller than it is, in a place the user had just emptied.
    if (!whole) return out;
    _index
      ..clear()
      ..addEntries([for (final c in out) MapEntry(c.id, _headerOf(c))]);
    _touchIndex();
    // The one place the index is waited for. Everywhere else it is written
    // behind the caller, but this is the *restore*, and a caller who has just
    // read the whole folder is entitled to assume the index agrees with it —
    // a test especially, which would otherwise tear its temp directory down
    // while the heal was still landing in it. One small file, next to the
    // hundreds of milliseconds the read above just spent.
    await _indexDraining;
    return out;
  }

  /// Every conversation's header — id, title, model, timestamps, which project
  /// it sits in, whether it is pinned or archived — with **no messages**.
  ///
  /// This is what the sidebar is drawn from on the way in. Reading the whole
  /// history to list it costs, measured on this machine's 119 chats (15 MB),
  /// 50 ms of disk and 137 ms of decode before the first row can appear; the
  /// index is 119 short objects and lands in about one.
  ///
  /// Deliberately does **not** await [settled], unlike [loadAll]: the file is
  /// replaced by rename so a reader never sees a torn one, and waiting for a
  /// write to land would give back exactly the delay this exists to avoid. The
  /// cost of that choice is that the index can be a beat behind — which is why
  /// nothing but the sidebar may be drawn from it, and why the headers it
  /// returns carry no messages to be mistaken for an empty transcript.
  ///
  /// Empty when there is no index yet — a first launch, or the first launch
  /// after upgrading from a build that never wrote one. The caller falls back to
  /// waiting for [loadAll], which is what every build before this did.
  Future<List<Conversation>> loadIndex() async {
    try {
      final raw = jsonDecode(await _indexFile.readAsString());
      if (raw is! Map || raw['chats'] is! List) return const [];
      final out = [
        for (final entry in raw['chats'] as List)
          if (entry is Map<String, dynamic>) ?_headerFrom(entry),
      ];
      out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return out;
    } on Object {
      // No index, or an unreadable one. Same leniency as a corrupt chat file:
      // the history is still on disk and [loadAll] will produce it.
      return const [];
    }
  }

  /// One conversation, whole, or null when there is no such file.
  ///
  /// The other half of [loadIndex]: the sidebar lists headers, and opening a row
  /// needs that chat's transcript before the user can be shown — or allowed to
  /// speak into — it.
  Future<Conversation?> load(String id) async {
    await settled;
    final file = _fileFor(id);
    if (!file.existsSync()) return null;
    return _read(file);
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
    _index[id] = _headerOf(conversation);
    _touchIndex();
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
    _index.remove(id);
    _touchIndex();
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
      // Compact, not indented. Nothing reads these by hand — `jq` is right
      // there when something does — and the indent cost 0.7 MB of the 9 MB chat
      // above, which is paid again on every launch, by the decode.
      await _atomicWrite(path, () => jsonEncode(conversation.toJson()));
    } on Object {
      // A disk that is full, a folder that has gone away, a chat deleted from
      // under the write. The conversation is in memory and on screen either
      // way, and there is nothing to tell the user to do about it here.
    }
  }

  /// Note the index has moved, and make sure something is on its way to write
  /// it out. Coalescing, like [save] — see [_indexDraining].
  void _touchIndex() {
    _indexDirty = true;
    _indexDraining ??= _track(_drainIndex());
  }

  Future<void> _drainIndex() async {
    try {
      while (_indexDirty) {
        _indexDirty = false;
        // A snapshot, taken before the await: the map goes on moving while the
        // write is in the air, and the loop condition is what catches that up.
        final headers = _index.values.toList();
        try {
          await _atomicWrite(
            _indexFile.path,
            () => jsonEncode({
              'chats': [for (final c in headers) c.toJson()],
            }),
          );
        } on Object {
          // Same as a chat that wouldn't write: the index is a way to draw the
          // sidebar sooner, and the sidebar is drawn without it either way.
        }
      }
    } finally {
      _indexDraining = null;
    }
  }

  /// Write what [encode] produces to [path] so that a reader sees either the
  /// whole of it or the previous file, never half of each.
  ///
  /// [encode] rather than a string, and this is not a style choice: it is called
  /// **inside** the isolate. Encoding at the call site instead puts the whole of
  /// `toJson` plus `jsonEncode` back on the caller's thread — measured at 37 ms
  /// for a 4,000-step chat, which is precisely the stall [save] exists to avoid,
  /// re-introduced by a line that reads like a tidy-up.
  ///
  /// Written beside the target and renamed over it, because `rename` is the one
  /// filesystem operation that is atomic. Writing in place — which this did —
  /// leaves a window as wide as the write itself, and on the chat that window
  /// was 28 ms of a 9 MB file: lose power there and the chat reloads as a
  /// truncated file, which [_read] then skips *silently*. The whole
  /// conversation, gone, with the app reporting nothing.
  ///
  /// The temporary carries a `.tmp` suffix on purpose — [loadAll] takes only
  /// names ending in `.json`, so one left behind by a crash is invisible to it
  /// rather than a corrupt chat to be skipped.
  Future<void> _atomicWrite(String path, String Function() encode) =>
      Isolate.run(() {
        final target = File(path);
        target.parent.createSync(recursive: true);
        final tmp = File('$path.tmp');
        tmp.writeAsStringSync(encode(), flush: true);
        tmp.renameSync(path);
      });

  /// [conversation] as the index holds it: everything the sidebar reads, and no
  /// transcript.
  ///
  /// Serialized by the conversation's own [Conversation.toJson], rather than by
  /// a second writer here, so a field added to a chat reaches the index by
  /// existing — a hand-rolled header is a thing that silently stops matching.
  Conversation _headerOf(Conversation conversation) =>
      conversation.messages.isEmpty
      ? conversation
      : conversation.copyWith(messages: const []);

  /// One stored header, or null when the entry is unusable — the same leniency
  /// [_read] gives a chat file, for the same reason.
  Conversation? _headerFrom(Map<String, dynamic> json) {
    try {
      return Conversation.fromJson(json);
    } on Object {
      return null;
    }
  }

  File get _indexFile => File('${_dir.path}/$kChatIndexName');

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

/// The sidebar's index, beside the conversations it lists. Not a chat id — every
/// id this app writes is a timestamp or `task-<hex>` — so it can share the
/// folder without ever colliding with one.
const String kChatIndexName = 'index.json';

/// The chat store, overridden in tests with a temp-dir-backed instance.
final chatStoreProvider = Provider<ChatStore>((ref) => ChatStore());
