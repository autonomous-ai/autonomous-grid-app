/// Files a paired phone has sent, assembled a chunk at a time.
///
/// **This is the only place a phone puts bytes on the computer**, so the limits
/// here are the whole of its budget rather than advice. Each one exists because
/// of something a channel like this can be made to do:
///
///  - [maxFileBytes] bounds one file, so a phone cannot fill the disk;
///  - [maxOpen] bounds how many are part-written at once, so it cannot fill it
///    with beginnings either;
///  - [maxChunkBytes] keeps a single frame far under the relay's 8 MB ceiling,
///    which it enforces by **ending the connection**, not by refusing a frame;
///  - [_staleAfter] drops what was started and abandoned, because an upload
///    nobody finished is a file nobody asked for.
///
/// Names from the phone are never trusted as paths: [_safeName] keeps a short,
/// alphanumeric extension — the desktop decides picture-or-document by it — and
/// throws everything else away. `holiday.JPEG` keeps `.jpeg`;
/// `../../.ssh/authorized_keys` keeps nothing at all, because what follows its
/// last dot is neither short nor alphanumeric, and lands as a random name in
/// this folder.
///
/// Flutter-free, like the rest of this folder.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// The most one file may weigh.
///
/// A phone photo is 2-5 MB and a slide deck can be 20; past this it is not an
/// attachment, it is a transfer, and it belongs somewhere with a progress bar
/// and a resume.
const int maxFileBytes = 25 * 1024 * 1024;

/// The most bytes one frame may carry, before base64 grows it by a third.
///
/// 384 KB becomes about 512 KB encoded — two orders under the relay's limit, so
/// a chunk can never be the thing that drops the channel.
const int maxChunkBytes = 384 * 1024;

/// How many uploads one phone may have open at once.
const int maxOpen = 8;

/// An upload that has not been added to in this long is abandoned.
const Duration _staleAfter = Duration(minutes: 10);

/// One file on its way in.
class MobileUpload {
  MobileUpload({
    required this.id,
    required this.name,
    required this.file,
    required this.declaredBytes,
  }) : touchedAt = DateTime.now();

  /// What the phone calls it back.
  final String id;

  /// The name it will carry into the chat — already made safe.
  final String name;

  /// Where the bytes are landing.
  final File file;

  /// What the phone said it would send, checked as it arrives.
  final int declaredBytes;

  /// When a chunk last landed, for [_staleAfter].
  DateTime touchedAt;

  /// How much has arrived so far.
  int received = 0;

  /// Whether every declared byte is in.
  bool get complete => received >= declaredBytes;
}

/// Holds part-written uploads and hands over the finished ones.
class MobileUploadStore {
  MobileUploadStore({required Directory directory, Random? random})
    : _dir = directory,
      _random = random ?? Random.secure();

  final Directory _dir;
  final Random _random;
  final _open = <String, MobileUpload>{};

  /// Starts one, or returns a sentence saying why not.
  ({String? id, String? problem}) begin({
    required String name,
    required int sizeBytes,
  }) {
    if (sizeBytes <= 0 || sizeBytes > maxFileBytes) {
      return (id: null, problem: 'That file is too big to send from a phone.');
    }
    _dropStale();
    if (_open.length >= maxOpen) {
      return (id: null, problem: 'Too many files at once. Try one or two.');
    }
    final id = _token();
    _dir.createSync(recursive: true);
    final upload = MobileUpload(
      id: id,
      name: _safeName(name, id),
      file: File('${_dir.path}/$id'),
      declaredBytes: sizeBytes,
    );
    upload.file.writeAsBytesSync(const []);
    _open[id] = upload;
    return (id: id, problem: null);
  }

  /// Adds one chunk. Null when it landed, else a sentence.
  String? addChunk(String id, String base64Chunk) {
    final upload = _open[id];
    if (upload == null) return 'That upload is no longer waiting.';
    final List<int> bytes;
    try {
      bytes = base64Decode(base64Chunk);
    } on FormatException {
      return 'That part of the file did not arrive intact.';
    }
    if (bytes.length > maxChunkBytes) return 'That piece is too large.';
    // Checked against what was declared, not just against the cap: a phone that
    // says 1 MB and then streams forever is the same problem as one that asks
    // for a file too big to begin with.
    if (upload.received + bytes.length > upload.declaredBytes) {
      return 'That file is bigger than it said it was.';
    }
    upload.file.writeAsBytesSync(bytes, mode: FileMode.append);
    upload.received += bytes.length;
    upload.touchedAt = DateTime.now();
    return null;
  }

  /// The finished uploads [ids] name, and what is wrong when one is not.
  ///
  /// All or nothing: a turn that quietly dropped one of three attachments is a
  /// turn answered about the wrong thing.
  ({List<MobileUpload>? files, String? problem}) take(List<String> ids) {
    final out = <MobileUpload>[];
    for (final id in ids) {
      final upload = _open[id];
      if (upload == null) return (files: null, problem: 'A file went missing.');
      if (!upload.complete) {
        return (files: null, problem: 'A file did not finish sending.');
      }
      out.add(upload);
    }
    for (final upload in out) {
      _open.remove(upload.id);
    }
    return (files: out, problem: null);
  }

  /// Forgets and deletes anything abandoned.
  void _dropStale() {
    final now = DateTime.now();
    for (final upload in _open.values.toList()) {
      if (now.difference(upload.touchedAt) <= _staleAfter) continue;
      _open.remove(upload.id);
      try {
        upload.file.deleteSync();
      } on FileSystemException {
        // Already gone, or the folder was cleared by hand. Nothing to do: the
        // record is dropped either way, which is the part that matters.
      }
    }
  }

  String _token() => [
    for (var i = 0; i < 12; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// A name that cannot be a path, keeping only the extension.
///
/// The extension is kept because the desktop decides image-or-document by it,
/// and dropped to 8 characters so it cannot smuggle a path either. Everything
/// else becomes [id], so two phones sending `photo.jpg` do not collide and no
/// name can climb out of the folder.
String _safeName(String name, String id) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return id;
  final extension = name
      .substring(dot + 1)
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (extension.isEmpty || extension.length > 8) return id;
  return '$id.$extension';
}
