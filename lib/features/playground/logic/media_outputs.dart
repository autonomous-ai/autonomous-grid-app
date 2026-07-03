import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/api/models/media_event.dart';
import 'chat_message.dart';
import 'message_media.dart';

/// Where generated media is written — `~/.grid/outputs` by default (the same
/// place the CLI saves them). Overridden in tests with a temp dir so they never
/// touch the real grid home.
final mediaOutputsDirProvider =
    Provider<Directory>((ref) => GridPaths.outputsDir);

/// Writes relay [files] to [dir] (cli.py:1125) and returns them as renderable
/// [ChatMedia]. Non-media or empty files are skipped. Each name is
/// de-duplicated so a second `image.png` never clobbers the first.
Future<List<ChatMedia>> saveMediaOutputs(
  List<MediaFile> files,
  Directory dir,
) async {
  await dir.create(recursive: true);

  final saved = <ChatMedia>[];
  for (final file in files) {
    final kind = mediaKindForPath(file.filename);
    if (kind == null) continue;
    final path = _unusedPath(dir.path, file.filename);
    await File(path).writeAsBytes(file.decodeBytes(), flush: true);
    saved.add(ChatMedia(path: path, kind: kind));
  }
  return saved;
}

/// `dir/name`, or `dir/name (2)` etc. when the file already exists — mirrors the
/// CLI's `_unused_path` so repeated generations don't overwrite each other.
String _unusedPath(String dir, String filename) {
  final safe = filename.split('/').last.split(r'\').last;
  var candidate = '$dir/$safe';
  if (!File(candidate).existsSync()) return candidate;

  final dot = safe.lastIndexOf('.');
  final stem = dot > 0 ? safe.substring(0, dot) : safe;
  final ext = dot > 0 ? safe.substring(dot) : '';
  for (var n = 2;; n++) {
    candidate = '$dir/$stem ($n)$ext';
    if (!File(candidate).existsSync()) return candidate;
  }
}
