import 'dart:io';

/// What [path] holds right now, or null when there is nothing honest to show —
/// the file doesn't exist yet, or can't be read as text (binary, permissions).
///
/// Null rather than an empty string on purpose: the callers draw a before/after
/// of a file an agent is about to change, and "" is a claim that the file was
/// empty, which is a different thing from not knowing.
String? readTextFileNow(String path) {
  if (path.isEmpty) return null;
  try {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  } on FileSystemException {
    return null;
  }
}
