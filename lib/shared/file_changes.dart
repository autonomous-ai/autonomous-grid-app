import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Word that some files on disk are no longer what the app last read.
///
/// Whoever writes announces it here; whoever is showing that file listens. The
/// two never have to know about each other, which is the point: the assistant
/// rewrites files today, and the terminal, a `git checkout` and a real
/// filesystem watcher all want to say the same thing tomorrow.
@immutable
class FileChangeNotice {
  const FileChangeNotice({required this.paths, required this.seq});

  /// Absolute paths, as they are on disk.
  final Set<String> paths;

  /// Which announcement this is. Two edits to one file are two events, and a
  /// listener that only saw the paths could not tell the second from a repeat
  /// of the first.
  final int seq;
}

/// The one place a file change is announced. See [FileChangeNotice].
final fileChangesProvider = NotifierProvider<FileChanges, FileChangeNotice>(
  FileChanges.new,
);

class FileChanges extends Notifier<FileChangeNotice> {
  int _seq = 0;

  @override
  FileChangeNotice build() => const FileChangeNotice(paths: {}, seq: 0);

  /// Say that [paths] have just been written, deleted, or restored.
  ///
  /// Cheap to call and safe to over-call: what it costs is a re-read by
  /// whichever screen happens to be showing one of those files, and nothing at
  /// all when none is.
  void touch(Iterable<String> paths) {
    final changed = paths.toSet();
    if (changed.isEmpty) return;
    state = FileChangeNotice(paths: Set.unmodifiable(changed), seq: ++_seq);
  }
}
