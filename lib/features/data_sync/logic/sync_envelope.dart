/// Everything Grid uploads is wrapped in this envelope, so a blob on the server
/// is self-describing without being readable.
///
/// Layout, in order:
///
/// ```
/// "GRIDSYNC"  8 bytes   so a truncated download is told apart from a wrong password
/// version     1 byte
/// headerLen   4 bytes   big-endian
/// header      JSON, UTF-8
/// nonce       12 bytes
/// ciphertext  the rest, with the 16-byte GCM tag last
/// ```
///
/// The header is authenticated (it is the AES-GCM *aad*) but not encrypted, and
/// that is what makes a backup self-contained. It carries which machine wrote
/// the version, how much is in it, which media it references — and the version's
/// own key, wrapped in the password that was typed for it. The server lifts
/// those into columns so the app can list backups and check a password without
/// downloading one; tampering with any of it breaks decryption on the client.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The magic bytes at the head of every envelope.
const String syncEnvelopeMagic = 'GRIDSYNC';

/// The envelope layout version. Bump only for a breaking layout change — the
/// *contents* of the header are additive and don't need it.
const int syncEnvelopeVersion = 1;

/// The one cipher this app writes. Named in the header so a future reader can
/// refuse a payload it doesn't understand instead of decrypting it wrongly.
const String syncEnvelopeAlgorithm = 'AES-256-GCM';

/// A snapshot: the zipped chats, prompts, projects and manifest.
const String syncEnvelopeKindSnapshot = 'snapshot';

/// One media file, stored on its own so it is uploaded once and reused.
const String syncEnvelopeKindObject = 'object';

const int _nonceLength = 12;
const int _macLength = 16;
const int _prefixLength = 8 + 1 + 4;

/// The bytes aren't a Grid sync payload at all — wrong magic, truncated, or a
/// header that isn't JSON.
///
/// Separate from [SyncDecryptException] because the two mean different things
/// to the person waiting: this one is a broken download, not a typo.
class SyncFormatException implements Exception {
  const SyncFormatException(this.message);

  final String message;

  @override
  String toString() => 'SyncFormatException: $message';
}

/// The payload is well-formed but this key doesn't open it — in practice, a
/// wrong password.
class SyncDecryptException implements Exception {
  const SyncDecryptException();

  @override
  String toString() => 'SyncDecryptException';
}

/// What an envelope says about itself before anything is decrypted.
class SyncEnvelopeHeader {
  const SyncEnvelopeHeader({
    required this.kind,
    this.createdAt,
    this.device,
    this.app,
    this.key,
    this.counts = const {},
    this.objectIds = const [],
  });

  /// [syncEnvelopeKindSnapshot] or [syncEnvelopeKindObject].
  final String kind;

  /// When the payload was sealed, UTC. Null for a media object: the same file
  /// must seal to the same bytes every time, and a timestamp would make each
  /// attempt differ — which is what would break recognising an upload as one
  /// already stored.
  final DateTime? createdAt;

  /// A human name for the machine that sealed it ("MacBook-Tony"), shown in the
  /// backup list. Null for a media object, for the same reason.
  final String? device;

  /// The app version that sealed it — the first thing worth knowing when a
  /// payload turns out to be unreadable by a later build.
  final String? app;

  /// This version's key, wrapped in the password typed for it — a
  /// `SyncKeyBlob` as JSON. Snapshots only.
  ///
  /// It travels with the payload rather than in a separate call so that a
  /// backup is one self-contained thing: the bytes that hold your chats also
  /// hold the (locked) key to them, and nothing else has to be kept in step.
  final Map<String, Object?>? key;

  /// How much is inside ("chats": 42), for the list the user picks from before
  /// they have typed anything.
  final Map<String, int> counts;

  /// The media objects this version references. Read by the server to know
  /// which media is still needed — it cannot see the manifest, which is inside
  /// the ciphertext.
  final List<String> objectIds;

  Map<String, Object?> toJson() => {
    'v': syncEnvelopeVersion,
    'alg': syncEnvelopeAlgorithm,
    'enc': kind,
    if (createdAt != null) 'created_at': createdAt!.toUtc().toIso8601String(),
    if (device != null) 'device': device,
    if (app != null) 'app': app,
    if (key != null) 'key': key,
    if (counts.isNotEmpty) 'counts': counts,
    if (objectIds.isNotEmpty) 'oids': objectIds,
  };

  /// Reads a header, tolerating fields it doesn't know so an older build can
  /// still open a payload a newer one wrote.
  factory SyncEnvelopeHeader.fromJson(Map<String, Object?> json) {
    final kind = json['enc'];
    if (kind is! String || kind.isEmpty) {
      throw const SyncFormatException('envelope header has no kind');
    }
    final createdAt = json['created_at'];
    final counts = json['counts'];
    final oids = json['oids'];
    return SyncEnvelopeHeader(
      kind: kind,
      createdAt: createdAt is String ? DateTime.tryParse(createdAt) : null,
      device: json['device'] is String ? json['device'] as String : null,
      app: json['app'] is String ? json['app'] as String : null,
      key: json['key'] is Map<String, Object?>
          ? json['key'] as Map<String, Object?>
          : null,
      counts: {
        if (counts is Map<String, Object?>)
          for (final entry in counts.entries)
            if (entry.value is int) entry.key: entry.value as int,
      },
      objectIds: [
        if (oids is List)
          for (final oid in oids)
            if (oid is String) oid,
      ],
    );
  }
}

/// Seals [plaintext] into an envelope readable only with [key].
///
/// [nonce] is for callers that need the output to be byte-identical across
/// runs (media objects, which are keyed by content); leave it null and a
/// random one is used, which is what a snapshot wants.
Future<Uint8List> sealSyncEnvelope({
  required List<int> plaintext,
  required SecretKey key,
  required SyncEnvelopeHeader header,
  List<int>? nonce,
}) async {
  final prefix = _framedHeader(header);
  final box = await AesGcm.with256bits().encrypt(
    plaintext,
    secretKey: key,
    nonce: nonce,
    aad: prefix,
  );
  final out = BytesBuilder(copy: false)
    ..add(prefix)
    ..add(box.nonce)
    ..add(box.cipherText)
    ..add(box.mac.bytes);
  return out.takeBytes();
}

/// Opens what [sealSyncEnvelope] wrote.
///
/// Throws [SyncFormatException] when [envelope] isn't a Grid payload and
/// [SyncDecryptException] when it is one but [key] doesn't open it. Callers
/// show those as two different sentences — "this file is damaged" and "wrong
/// password" send the user to two different places.
Future<Uint8List> openSyncEnvelope({
  required List<int> envelope,
  required SecretKey key,
}) async {
  final bytes = Uint8List.fromList(envelope);
  final headerEnd = _headerEnd(bytes);
  final bodyStart = headerEnd + _nonceLength;
  if (bytes.length < bodyStart + _macLength) {
    throw const SyncFormatException('payload is truncated');
  }
  final box = SecretBox(
    bytes.sublist(bodyStart, bytes.length - _macLength),
    nonce: bytes.sublist(headerEnd, bodyStart),
    mac: Mac(bytes.sublist(bytes.length - _macLength)),
  );
  try {
    final clear = await AesGcm.with256bits().decrypt(
      box,
      secretKey: key,
      aad: bytes.sublist(0, headerEnd),
    );
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const SyncDecryptException();
  }
}

/// The header of [envelope], without decrypting anything.
SyncEnvelopeHeader readSyncEnvelopeHeader(List<int> envelope) {
  final bytes = Uint8List.fromList(envelope);
  final end = _headerEnd(bytes);
  final json = _decodeHeader(bytes.sublist(_prefixLength, end));
  return SyncEnvelopeHeader.fromJson(json);
}

Uint8List _framedHeader(SyncEnvelopeHeader header) {
  final json = utf8.encode(jsonEncode(header.toJson()));
  final out = BytesBuilder(copy: false)
    ..add(ascii.encode(syncEnvelopeMagic))
    ..addByte(syncEnvelopeVersion)
    ..add(_uint32(json.length))
    ..add(json);
  return out.takeBytes();
}

/// Where the header stops, after checking everything before it.
int _headerEnd(Uint8List bytes) {
  if (bytes.length < _prefixLength) {
    throw const SyncFormatException('payload is too short to be a sync file');
  }
  final magic = ascii.decode(bytes.sublist(0, 8), allowInvalid: true);
  if (magic != syncEnvelopeMagic) {
    throw const SyncFormatException('not a Grid sync file');
  }
  if (bytes[8] != syncEnvelopeVersion) {
    throw SyncFormatException('sync format v${bytes[8]} is not supported');
  }
  final length = ByteData.sublistView(bytes, 9, 13).getUint32(0);
  final end = _prefixLength + length;
  if (length == 0 || end > bytes.length) {
    throw const SyncFormatException('payload header is truncated');
  }
  return end;
}

Map<String, Object?> _decodeHeader(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const SyncFormatException('payload header is not an object');
    }
    return decoded;
  } on FormatException {
    throw const SyncFormatException('payload header is not readable');
  }
}

Uint8List _uint32(int value) {
  final out = ByteData(4)..setUint32(0, value);
  return out.buffer.asUint8List();
}
