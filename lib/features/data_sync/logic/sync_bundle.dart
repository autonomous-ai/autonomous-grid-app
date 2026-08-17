/// What goes inside a snapshot, and what is deliberately left out of it.
///
/// A snapshot is a zip of the small, portable things — the chat files, the
/// project list, and a [SyncManifest] describing them.
/// Media never goes in: an image is uploaded once as its own object and
/// referenced by id, so a second upload of a hundred unchanged photos costs
/// nothing. Everything here is pure — bytes in, bytes out — so the rules can
/// be tested without a disk or a server.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'sync_envelope.dart';

/// Entry names inside the archive. Fixed strings: a reader on another machine
/// finds files by these, not by scanning.
const String syncManifestEntry = 'manifest.json';
const String syncChatsPrefix = 'chats/';
const String syncProjectsEntry = 'projects.json';

/// The largest media file that will be uploaded, matching the control plane's
/// per-object cap. Anything bigger is recorded in [SyncManifest.skipped] so the
/// other machine can say why a picture isn't there.
const int syncMaxObjectBytes = 25 * 1024 * 1024;

/// Why a referenced file didn't travel.
enum SyncSkipReason {
  /// It lives outside `~/.grid/outputs` — a file the user attached from their
  /// own folders. Grid syncs what Grid made; someone's Desktop is not ours to
  /// copy to another machine. The chat still carries the text read out of it.
  outsideOutputs,

  /// Bigger than [syncMaxObjectBytes].
  tooLarge,

  /// Referenced by a chat but no longer on this disk.
  missing,
}

/// One media file that made it into the upload.
class SyncMediaEntry {
  const SyncMediaEntry({
    required this.oid,
    required this.key,
    required this.source,
    required this.rel,
    required this.bytes,
  });

  /// The object's name on the server — see `sealSyncMedia`.
  final String oid;

  /// The key that opens this object, derived from the file's own contents.
  ///
  /// It lives in the manifest, which is inside the encrypted snapshot, so a
  /// version's password opens exactly the media that version references — and
  /// media stays shareable between versions with different passwords.
  final List<int> key;

  /// The path exactly as the chat file spells it, on the machine that packed
  /// the snapshot. It is the key the merge matches on, so the rewrite is an
  /// exact lookup rather than a guess about how two machines name things.
  final String source;

  /// The same file relative to `~/.grid` (`outputs/…`), kept for display and
  /// for choosing a sensible name when unpacking.
  final String rel;

  final int bytes;

  Map<String, Object?> toJson() => {
    'oid': oid,
    'key': base64.encode(key),
    'source': source,
    'rel': rel,
    'bytes': bytes,
  };

  static SyncMediaEntry? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final oid = raw['oid'];
    final source = raw['source'];
    final key = raw['key'];
    if (oid is! String || source is! String || key is! String) return null;
    final List<int> decoded;
    try {
      decoded = base64.decode(key);
    } on FormatException {
      return null;
    }
    return SyncMediaEntry(
      oid: oid,
      key: decoded,
      source: source,
      rel: raw['rel'] is String ? raw['rel'] as String : source,
      bytes: raw['bytes'] is int ? raw['bytes'] as int : 0,
    );
  }
}

/// One media file that didn't, and why.
class SyncSkippedMedia {
  const SyncSkippedMedia({
    required this.source,
    required this.reason,
    this.bytes = 0,
  });

  final String source;
  final SyncSkipReason reason;
  final int bytes;

  Map<String, Object?> toJson() => {
    'source': source,
    'reason': reason.name,
    'bytes': bytes,
  };

  static SyncSkippedMedia? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final source = raw['source'];
    if (source is! String) return null;
    return SyncSkippedMedia(
      source: source,
      reason: _reasonNamed(raw['reason']),
      bytes: raw['bytes'] is int ? raw['bytes'] as int : 0,
    );
  }

  static SyncSkipReason _reasonNamed(Object? raw) {
    for (final reason in SyncSkipReason.values) {
      if (reason.name == raw) return reason;
    }
    return SyncSkipReason.missing;
  }
}

/// The index at the head of a snapshot: what it holds, where it came from, and
/// which media objects belong to it.
class SyncManifest {
  const SyncManifest({
    required this.createdAt,
    required this.device,
    required this.app,
    required this.chatCount,
    required this.projectCount,
    this.media = const [],
    this.skipped = const [],
  });

  final DateTime createdAt;
  final String device;
  final String app;
  final int chatCount;
  final int projectCount;
  final List<SyncMediaEntry> media;
  final List<SyncSkippedMedia> skipped;

  /// The ids the server must be holding for this snapshot to be complete —
  /// also what the object garbage collector must not delete.
  List<String> get objectIds => [for (final entry in media) entry.oid];

  Map<String, Object?> toJson() => {
    'v': 1,
    'created_at': createdAt.toUtc().toIso8601String(),
    'device': device,
    'app': app,
    'counts': {
      'chats': chatCount,
      'projects': projectCount,
      'media': media.length,
    },
    'media': [for (final entry in media) entry.toJson()],
    'skipped': [for (final entry in skipped) entry.toJson()],
  };

  /// Reads a manifest, tolerating anything it doesn't recognise so a snapshot
  /// written by a newer build still opens here.
  factory SyncManifest.fromJson(Map<String, Object?> json) {
    final counts = json['counts'];
    final byName = counts is Map<String, Object?> ? counts : const {};
    final createdAt = json['created_at'];
    return SyncManifest(
      createdAt:
          (createdAt is String ? DateTime.tryParse(createdAt) : null)
              ?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      device: json['device'] is String ? json['device'] as String : 'unknown',
      app: json['app'] is String ? json['app'] as String : '',
      chatCount: byName['chats'] is int ? byName['chats'] as int : 0,
      projectCount: byName['projects'] is int ? byName['projects'] as int : 0,
      media: [
        if (json['media'] is List)
          for (final raw in json['media'] as List)
            ?SyncMediaEntry.fromJson(raw),
      ],
      skipped: [
        if (json['skipped'] is List)
          for (final raw in json['skipped'] as List)
            ?SyncSkippedMedia.fromJson(raw),
      ],
    );
  }
}

/// A candidate media file: the path a chat spells, and its size — null when
/// the file isn't on this disk any more.
typedef SyncMediaCandidate = ({String path, int? bytes});

/// A file that will travel, before it has been sealed and given an id.
typedef SyncMediaPick = ({String source, String rel, int bytes});

/// The outcome of [planSyncMedia]: what to upload, and what to explain away.
typedef SyncMediaPlan = ({
  List<SyncMediaPick> picked,
  List<SyncSkippedMedia> skipped,
});

/// Every local file path the chats point at, deduplicated, in first-seen order.
///
/// Reads the *generic* map rather than a parsed `Conversation` on purpose: this
/// runs over files another build may have written, and a round trip through a
/// model this build knows would drop fields it doesn't.
List<String> referencedMediaPaths(Iterable<Map<String, Object?>> chats) {
  final out = <String>{};
  for (final chat in chats) {
    final messages = chat['messages'];
    if (messages is! List) continue;
    for (final message in messages) {
      if (message is! Map<String, Object?>) continue;
      out.addAll(_pathsIn(message['media']));
      out.addAll(_pathsIn(message['files']));
    }
  }
  return out.toList();
}

Iterable<String> _pathsIn(Object? raw) sync* {
  if (raw is! List) return;
  for (final item in raw) {
    if (item is! Map<String, Object?>) continue;
    final path = item['path'];
    if (path is String && path.isNotEmpty) yield path;
  }
}

/// Decides which of [candidates] travel with the snapshot.
///
/// [outputsPath] is this machine's `~/.grid/outputs`; only files under it are
/// Grid's own output and therefore ours to copy. Pure: the caller does the
/// stat'ing, which is what makes every branch here testable.
SyncMediaPlan planSyncMedia({
  required List<SyncMediaCandidate> candidates,
  required String outputsPath,
  int maxBytes = syncMaxObjectBytes,
}) {
  final prefix = outputsPath.endsWith('/') ? outputsPath : '$outputsPath/';
  final picked = <SyncMediaPick>[];
  final skipped = <SyncSkippedMedia>[];
  for (final candidate in candidates) {
    final path = candidate.path;
    if (!path.startsWith(prefix)) {
      skipped.add(
        SyncSkippedMedia(
          source: path,
          reason: SyncSkipReason.outsideOutputs,
          bytes: candidate.bytes ?? 0,
        ),
      );
      continue;
    }
    final bytes = candidate.bytes;
    if (bytes == null) {
      skipped.add(
        SyncSkippedMedia(source: path, reason: SyncSkipReason.missing),
      );
      continue;
    }
    if (bytes > maxBytes) {
      skipped.add(
        SyncSkippedMedia(
          source: path,
          reason: SyncSkipReason.tooLarge,
          bytes: bytes,
        ),
      );
      continue;
    }
    // Sealing — and with it the id and the key — happens in the caller, which
    // reads the file. Planning stays free of crypto and of the disk, so every
    // branch above is testable on plain values.
    picked.add((
      source: path,
      rel: 'outputs/${path.substring(prefix.length)}',
      bytes: bytes,
    ));
  }
  return (picked: picked, skipped: skipped);
}

/// Zips [entries] (entry name → bytes) into the snapshot's payload.
Uint8List packSyncArchive(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// Unzips what [packSyncArchive] made.
///
/// Rejects entry names that could escape the folder they're unpacked into: the
/// bytes came off a server, and a snapshot is unpacked next to the user's real
/// chat history.
Map<String, Uint8List> unpackSyncArchive(List<int> zipped) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipped);
  } on Object {
    throw const SyncFormatException('snapshot could not be unpacked');
  }
  final out = <String, Uint8List>{};
  for (final file in archive) {
    final name = file.name;
    if (!file.isFile) continue;
    if (name.startsWith('/') || name.contains('..')) {
      throw SyncFormatException('snapshot has an unsafe entry "$name"');
    }
    final bytes = file.readBytes();
    if (bytes != null) out[name] = bytes;
  }
  return out;
}

/// The manifest out of an unpacked snapshot.
SyncManifest readSyncManifest(Map<String, Uint8List> entries) {
  final raw = entries[syncManifestEntry];
  if (raw == null) {
    throw const SyncFormatException('snapshot has no manifest');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(raw));
  } on FormatException {
    throw const SyncFormatException('snapshot manifest is not readable');
  }
  if (decoded is! Map<String, Object?>) {
    throw const SyncFormatException('snapshot manifest is not an object');
  }
  return SyncManifest.fromJson(decoded);
}
