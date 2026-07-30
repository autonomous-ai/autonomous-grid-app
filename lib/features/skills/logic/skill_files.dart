import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One file inside a skill's folder, named the way the card names it.
class SkillFile {
  const SkillFile({required this.relativePath, required this.sizeBytes});

  /// Path relative to the skill's own folder — `SKILL.md`,
  /// `scripts/generate.py`, `assets/fonts/inter.ttf`. Relative because that's
  /// how a card refers to its own files, and how the user thinks of them.
  final String relativePath;

  final int sizeBytes;

  /// The folder this file sits in, or empty at the top — what the viewer groups
  /// the list by, so a skill with twenty assets doesn't read as one long run.
  String get folder {
    final cut = relativePath.lastIndexOf('/');
    return cut == -1 ? '' : relativePath.substring(0, cut);
  }

  String get name => relativePath.split('/').last;
}

/// What a skill folder holds, `SKILL.md` first.
///
/// The card comes first because it's the file anyone opening a skill wants: it
/// says what the skill does. The rest follow by path, so a folder's files stay
/// together and the order doesn't change between reads.
Future<List<SkillFile>> listSkillFiles(String skillPath) async {
  final dir = Directory(skillPath);
  if (!dir.existsSync()) return const [];
  final files = <SkillFile>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    files.add(
      SkillFile(
        relativePath: entity.path.substring(skillPath.length + 1),
        sizeBytes: await entity.length(),
      ),
    );
  }
  files.sort((a, b) {
    final aCard = a.relativePath == kSkillCardName;
    final bCard = b.relativePath == kSkillCardName;
    if (aCard != bCard) return aCard ? -1 : 1;
    return a.relativePath.compareTo(b.relativePath);
  });
  return files;
}

/// The card every skill folder is built around.
const String kSkillCardName = 'SKILL.md';

/// A file's text, or a line saying why it isn't being shown.
///
/// The viewer is for reading a skill, not for opening whatever happens to be in
/// the folder: a font or a screenshot has no text to show, and a huge file would
/// freeze the dialog laying it out. Both come back as a sentence rather than an
/// error — the file is still listed, and "what is this" is answered either way.
Future<String> readSkillFile(String path) async {
  final file = File(path);
  if (!file.existsSync()) return 'This file is no longer on disk.';
  final size = await file.length();
  if (size > kSkillFileTextLimit) {
    return 'Too big to show here (${formatSkillFileSize(size)}).';
  }
  final bytes = await file.readAsBytes();
  // A NUL byte inside the first stretch is the cheap, reliable tell for "not
  // text" — no text file the app writes contains one.
  if (bytes.take(1024).contains(0)) {
    return 'Not a text file (${formatSkillFileSize(size)}).';
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return 'Not readable as text (${formatSkillFileSize(size)}).';
  }
}

/// 512 KB — past this a file is not something anyone reads in a dialog, and
/// laying it out costs a visible stall.
const int kSkillFileTextLimit = 512 * 1024;

String formatSkillFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The files in one skill's folder. Auto-disposed: read while a viewer is open,
/// dropped with it.
final skillFilesProvider = FutureProvider.autoDispose.family<List<SkillFile>, String>(
  (ref, skillPath) => listSkillFiles(skillPath),
);

/// One file's text, keyed by its absolute path.
final skillFileTextProvider = FutureProvider.autoDispose.family<String, String>(
  (ref, path) => readSkillFile(path),
);
