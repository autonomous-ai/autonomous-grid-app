import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
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

/// A skill folder to read, wherever it is.
///
/// Two places, one viewer: a skill installed on disk, and one still sitting in
/// the bundled catalog. The screen that shows a skill's files shouldn't care
/// which — and the catalog's whole point is being able to read a skill *before*
/// installing it.
typedef SkillFolder = ({bool fromAssets, String location});

/// A folder on disk, by absolute path.
SkillFolder diskSkillFolder(String path) => (fromAssets: false, location: path);

/// A folder in the asset bundle, by its key prefix.
SkillFolder assetSkillFolder(String prefix) =>
    (fromAssets: true, location: prefix);

/// One file within a folder — the key the text provider is read by.
typedef SkillFileRef = ({SkillFolder folder, String relativePath});

/// The card every skill folder is built around — the file that makes a folder
/// a skill, and the first thing the viewer opens.
const String kSkillCardFileName = 'SKILL.md';

/// The bundle the catalog is read from. Overridable so a test can hand it a few
/// skills instead of the real six megabytes.
final publicSkillBundleProvider = Provider<AssetBundle>((ref) => rootBundle);

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
  return _cardFirst(files);
}

/// The same list for a skill still in the bundle.
///
/// Sizes cost a read here — the asset manifest carries names, not lengths — so
/// this loads the folder. A skill is a card and a handful of scripts; the
/// viewer is about to read one of them anyway.
Future<List<SkillFile>> listAssetSkillFiles(
  AssetBundle bundle,
  String prefix,
) async {
  final manifest = await AssetManifest.loadFromAssetBundle(bundle);
  final files = <SkillFile>[];
  for (final key in manifest.listAssets()) {
    if (!key.startsWith('$prefix/')) continue;
    files.add(
      SkillFile(
        relativePath: key.substring(prefix.length + 1),
        sizeBytes: (await bundle.load(key)).lengthInBytes,
      ),
    );
  }
  return _cardFirst(files);
}

List<SkillFile> _cardFirst(List<SkillFile> files) {
  files.sort((a, b) {
    final aCard = a.relativePath == kSkillCardFileName;
    final bCard = b.relativePath == kSkillCardFileName;
    if (aCard != bCard) return aCard ? -1 : 1;
    return a.relativePath.compareTo(b.relativePath);
  });
  return files;
}

/// A file's text, or a line saying why it isn't being shown.
Future<String> readSkillFile(String path) async {
  final file = File(path);
  if (!file.existsSync()) return 'This file is no longer on disk.';
  return skillFileText(await file.readAsBytes());
}

/// The same, for a file in the bundle.
Future<String> readAssetSkillFile(AssetBundle bundle, String key) async {
  final ByteData data;
  try {
    data = await bundle.load(key);
  } on Object {
    return "This file isn't in the bundle.";
  }
  return skillFileText(data.buffer.asUint8List());
}

/// Decide what to show for [bytes].
///
/// The viewer is for reading a skill, not for opening whatever happens to be in
/// the folder: a font or a screenshot has no text to show, and a huge file
/// would freeze the dialog laying it out. Both come back as a sentence rather
/// than an error — the file is still listed, and "what is this" is answered
/// either way.
String skillFileText(Uint8List bytes) {
  if (bytes.length > kSkillFileTextLimit) {
    return 'Too big to show here (${formatSkillFileSize(bytes.length)}).';
  }
  // A NUL byte inside the first stretch is the cheap, reliable tell for "not
  // text" — no text file the app writes contains one.
  if (bytes.take(1024).contains(0)) {
    return 'Not a text file (${formatSkillFileSize(bytes.length)}).';
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return 'Not readable as text (${formatSkillFileSize(bytes.length)}).';
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

/// The files in one skill folder. Auto-disposed: read while a viewer is open,
/// dropped with it.
final skillFilesProvider = FutureProvider.autoDispose
    .family<List<SkillFile>, SkillFolder>((ref, folder) {
      if (!folder.fromAssets) return listSkillFiles(folder.location);
      return listAssetSkillFiles(
        ref.watch(publicSkillBundleProvider),
        folder.location,
      );
    });

/// One file's text.
final skillFileTextProvider = FutureProvider.autoDispose
    .family<String, SkillFileRef>((ref, file) {
      final path = '${file.folder.location}/${file.relativePath}';
      if (!file.folder.fromAssets) return readSkillFile(path);
      return readAssetSkillFile(ref.watch(publicSkillBundleProvider), path);
    });
