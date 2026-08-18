import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_changes.dart';

/// How long a burst of writes is allowed to settle before it is announced.
///
/// A build or a `git checkout` writes hundreds of files in a few milliseconds,
/// and each one on its own would be a re-read of the folder listing. Waiting for
/// the quiet after the storm turns that into one.
const _settle = Duration(milliseconds: 120);

/// Watch one folder — not the folders inside it — and announce what changes
/// there on [fileChangesProvider].
///
/// In `shared/` because two features need the same watcher: the Files panel keeps
/// one per folder it is showing, and Docs keeps one on the folder of the document
/// it has open — an assistant that edits a `.docx` through a shell script writes
/// it with nobody announcing anything, so the only word Docs gets is from the
/// filesystem itself.
///
/// Non-recursive on purpose. Linux's inotify has no recursive mode, so
/// `recursive: true` would quietly mean three different things on the three
/// platforms this ships to; one watcher per folder the panel is actually showing
/// is the same laziness the listing already has, and it is honest everywhere.
///
/// A folder that can't be watched — gone, a network mount, the platform's watch
/// limit reached — is left alone rather than raised: the listing still works and
/// the toolbar's re-read button still does what it always did.
final folderWatchProvider = Provider.autoDispose.family<void, String>((
  ref,
  path,
) {
  StreamSubscription<FileSystemEvent>? events;
  Timer? settle;
  final pending = <String>{};

  void flush() {
    if (pending.isEmpty) return;
    ref.read(fileChangesProvider.notifier).touch(pending);
    pending.clear();
  }

  void onEvent(FileSystemEvent event) {
    pending.add(event.path);
    // A rename is two facts: the name that went and the name that arrived. Only
    // the second is in `path`.
    if (event is FileSystemMoveEvent) {
      final destination = event.destination;
      if (destination != null) pending.add(destination);
    }
    settle?.cancel();
    settle = Timer(_settle, flush);
  }

  try {
    // Errors on the stream are the folder becoming unwatchable underneath us —
    // deleted, unmounted. Nothing to tell the user: what they see next is the
    // listing failing to read, which says it in its own words.
    events = Directory(path).watch().listen(onEvent, onError: (Object _) {});
  } on FileSystemException {
    return;
  }

  ref.onDispose(() {
    settle?.cancel();
    unawaited(events?.cancel());
  });
});
