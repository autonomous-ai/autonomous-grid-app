/// The keys behind Sync & Backup, and why there is more than one kind.
///
/// **Each backup carries its own key.** Uploading generates 32 random bytes, seals that
/// version with them, and wraps *those bytes* in the password the user typed —
/// [SyncKeyBlob], which travels in the version's own header. Two backups can
/// therefore carry two different passwords, and forgetting one costs exactly that
/// version. The password never encrypts a byte of the user's data itself; it only
/// unlocks 32 bytes, which is what makes checking it cost one second instead of a
/// download.
///
/// **Media is keyed by its own contents.** A photo's key is derived from the photo
/// ([sealSyncMedia]) rather than from any version's key, so the same file always
/// seals to the same bytes under the same id — and is therefore uploaded once, no
/// matter how many versions reference it or which passwords those versions carry.
/// Each version's manifest carries the keys for the media it references, so a
/// password opens exactly the media that version needs.
///
/// The trade-off in that last choice, stated because it is real: anyone holding the
/// database who can *guess a file's exact bytes* can confirm the account stores it.
/// They still cannot read anything they cannot already reproduce. For pictures Grid
/// itself generated, that is a threat on paper.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'sync_envelope.dart';

/// Argon2id parameters, OWASP's 2024 recommendation (m=19 MiB, t=2, p=1).
///
/// They ride in the [SyncKeyBlob] rather than being assumed, so raising them later
/// doesn't lock anyone out of a backup wrapped with today's numbers.
const int syncKdfMemoryKib = 19456;
const int syncKdfIterations = 2;
const int syncKdfParallelism = 1;

/// The name written into [SyncKeyBlob.kdf]; the only one this build accepts.
const String syncKdfArgon2id = 'argon2id';

/// The most a *stored* blob may ask this machine to spend unwrapping it.
///
/// The parameters ride in the blob so they can be raised later without locking
/// anyone out — which means they are a number this app takes from a record the
/// server hands back, and runs an allocator on. Left unbounded, a `m` of a few
/// million KiB is an out-of-memory kill of the whole app at the moment somebody
/// opens the backup list, from a value nobody here typed.
///
/// Generous rather than tight: a hundredfold over today's 19 MiB leaves every
/// realistic hardening ahead of us inside the bound, so this only ever refuses a
/// figure that is a mistake or an attack. A refusal costs that one backup's row
/// (`SyncClient.listVersions` skips it) — never the list.
const int syncKdfMaxMemoryKib = 2 * 1024 * 1024;
const int syncKdfMaxIterations = 64;
const int syncKdfMaxParallelism = 16;

/// Bytes in a version key, and in every key derived from a media file.
const int syncKeyLength = 32;

/// The shortest password the app will wrap a backup with.
///
/// There is no server-side rate limit to hide behind — an attacker who takes the
/// database attacks the password offline, and Argon2id's cost per guess is the only
/// thing standing there. Ten characters is the floor; the UI pushes for a passphrase.
const int syncPasswordMinLength = 10;

/// Media is sealed with an all-zero nonce, deliberately.
///
/// Safe here and only here: a media key is a function of the file's own contents, so
/// no key ever sees a second plaintext — the condition a repeated GCM nonce would
/// break. In exchange the same file always seals to the same bytes, which is what
/// makes an already-uploaded file recognisable.
final Uint8List syncMediaNonce = Uint8List(12);

const String _wrapAad = 'grid-sync/key/v1';
const String _mediaInfo = 'grid-sync/object';

/// A version's key as it is stored: wrapped in the password used for that upload.
class SyncKeyBlob {
  const SyncKeyBlob({
    required this.salt,
    required this.nonce,
    required this.wrapped,
    this.kdf = syncKdfArgon2id,
    this.memoryKib = syncKdfMemoryKib,
    this.iterations = syncKdfIterations,
    this.parallelism = syncKdfParallelism,
    this.hint,
  });

  final List<int> salt;
  final List<int> nonce;

  /// The version key, encrypted: 32 bytes of key plus the 16-byte GCM tag. That tag
  /// is what tells a wrong password from a right one, locally and immediately.
  final List<int> wrapped;

  final String kdf;
  final int memoryKib;
  final int iterations;
  final int parallelism;

  /// The user's own reminder, shown beside the password prompt. Optional, and the
  /// only field here anyone but the user can read — so the UI must say so.
  final String? hint;

  Map<String, Object?> toJson() => {
    'v': 1,
    'kdf': kdf,
    'm': memoryKib,
    't': iterations,
    'p': parallelism,
    'salt': base64.encode(salt),
    'nonce': base64.encode(nonce),
    'wrapped': base64.encode(wrapped),
    if (hint != null && hint!.isNotEmpty) 'hint': hint,
  };

  /// Parses what the control plane listed for one version.
  ///
  /// Throws [SyncFormatException] rather than returning null: a backup whose key
  /// record can't be read is not a state the UI can offer an action for.
  factory SyncKeyBlob.fromJson(Map<String, Object?> json) {
    final kdf = json['kdf'];
    if (kdf != syncKdfArgon2id) {
      throw SyncFormatException('unsupported key derivation "$kdf"');
    }
    return SyncKeyBlob(
      salt: _bytes(json['salt'], 'salt'),
      nonce: _bytes(json['nonce'], 'nonce'),
      wrapped: _bytes(json['wrapped'], 'wrapped'),
      memoryKib: _cost(json['m'], syncKdfMemoryKib, syncKdfMaxMemoryKib, 'm'),
      iterations: _cost(json['t'], syncKdfIterations, syncKdfMaxIterations, 't'),
      parallelism: _cost(
        json['p'],
        syncKdfParallelism,
        syncKdfMaxParallelism,
        'p',
      ),
      hint: json['hint'] is String ? json['hint'] as String : null,
    );
  }

  factory SyncKeyBlob.decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const SyncFormatException('key record is not readable');
    }
    if (decoded is! Map<String, Object?>) {
      throw const SyncFormatException('key record is not an object');
    }
    return SyncKeyBlob.fromJson(decoded);
  }

  static List<int> _bytes(Object? raw, String field) {
    if (raw is! String) throw SyncFormatException('key record has no $field');
    try {
      return base64.decode(raw);
    } on FormatException {
      throw SyncFormatException('key record has an unreadable $field');
    }
  }

  /// One KDF cost parameter, refused when it is outside what this machine will
  /// agree to spend.
  ///
  /// A missing or non-integer value falls back to today's figure — an old blob
  /// that predates the field is readable, which is the whole reason the
  /// parameters travel. A value that is *present and out of range* is a
  /// different thing and must not fall back: silently substituting the default
  /// would derive the wrong key and report it as a wrong password, sending
  /// somebody to re-type a password that was right.
  static int _cost(Object? raw, int fallback, int ceiling, String field) {
    if (raw is! int) return fallback;
    if (raw < 1 || raw > ceiling) {
      throw SyncFormatException(
        'key record asks for $field=$raw, outside the 1..$ceiling this build '
        'will spend on one backup',
      );
    }
    return raw;
  }
}

/// The key that seals one backup.
///
/// Held in memory only for the length of one upload or download — never written to
/// disk, never sent anywhere unwrapped.
class SyncVersionKey {
  const SyncVersionKey(this.bytes);

  /// 32 raw bytes, freshly generated for each upload.
  final List<int> bytes;

  factory SyncVersionKey.generate() =>
      SyncVersionKey(SecretKeyData.random(length: syncKeyLength).bytes);

  SecretKey get secretKey => SecretKey(bytes);

  /// Wraps this key in [password] — what rides in the version's header.
  ///
  /// A fresh salt and nonce every time, so two versions wrapped with the *same*
  /// password produce unrelated blobs and give nothing away by comparison.
  Future<SyncKeyBlob> wrap({required String password, String? hint}) async {
    final salt = SecretKeyData.random(length: 16).bytes;
    final kek = await _deriveKek(
      password: password,
      salt: salt,
      memoryKib: syncKdfMemoryKib,
      iterations: syncKdfIterations,
      parallelism: syncKdfParallelism,
    );
    final box = await AesGcm.with256bits().encrypt(
      bytes,
      secretKey: SecretKey(kek),
      aad: ascii.encode(_wrapAad),
    );
    return SyncKeyBlob(
      salt: salt,
      nonce: box.nonce,
      wrapped: [...box.cipherText, ...box.mac.bytes],
      hint: hint,
    );
  }

  /// Recovers a version's key from [blob] with [password].
  ///
  /// Throws [SyncDecryptException] when the password is wrong. This is *the*
  /// password check: it needs 48 bytes and about a second, so the app can say "wrong
  /// password" before compressing, uploading or downloading anything.
  static Future<SyncVersionKey> unwrap({
    required SyncKeyBlob blob,
    required String password,
  }) async {
    final kek = await _deriveKek(
      password: password,
      salt: blob.salt,
      memoryKib: blob.memoryKib,
      iterations: blob.iterations,
      parallelism: blob.parallelism,
    );
    if (blob.wrapped.length <= 16) {
      throw const SyncFormatException('key record is truncated');
    }
    final split = blob.wrapped.length - 16;
    try {
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          blob.wrapped.sublist(0, split),
          nonce: blob.nonce,
          mac: Mac(blob.wrapped.sublist(split)),
        ),
        secretKey: SecretKey(kek),
        aad: ascii.encode(_wrapAad),
      );
      return SyncVersionKey(clear);
    } on SecretBoxAuthenticationError {
      throw const SyncDecryptException();
    }
  }
}

/// One media file, sealed and ready to upload.
typedef SyncSealedMedia = ({String oid, List<int> key, Uint8List envelope});

/// Seals [content] with a key derived from [content] itself.
///
/// The id is the hash of the *ciphertext*, so the server learns nothing from it that
/// it doesn't already hold, and the same file always produces the same id — which is
/// what lets an upload skip the photos it sent last time, across password changes and
/// across machines.
Future<SyncSealedMedia> sealSyncMedia(List<int> content) async {
  final key = await _mediaKey(content);
  final envelope = await sealSyncEnvelope(
    plaintext: content,
    key: SecretKey(key),
    header: const SyncEnvelopeHeader(kind: syncEnvelopeKindObject),
    nonce: syncMediaNonce,
  );
  final digest = await Sha256().hash(envelope);
  return (oid: _hex(digest.bytes), key: key, envelope: envelope);
}

/// Opens a media object with the key its manifest recorded.
Future<Uint8List> openSyncMedia({
  required List<int> envelope,
  required List<int> key,
}) => openSyncEnvelope(envelope: envelope, key: SecretKey(key));

Future<List<int>> _mediaKey(List<int> content) async {
  final digest = await Sha256().hash(content);
  final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: syncKeyLength)
      .deriveKey(
        secretKey: SecretKey(digest.bytes),
        info: ascii.encode(_mediaInfo),
      );
  return derived.extractBytes();
}

/// How usable a password is, in the only terms that matter here: how long an offline
/// attacker holding the database would need.
enum SyncPasswordVerdict {
  /// Below [syncPasswordMinLength] — the app refuses it.
  tooShort,

  /// Long enough but predictable (one repeated character, digits only, or a password
  /// everybody uses). Allowed, with a warning.
  weak,

  /// Nothing obviously wrong with it.
  ok,
}

/// Judges [password] for the upload dialog.
///
/// Deliberately crude: it catches the shapes that fall in seconds and doesn't pretend
/// to score entropy. The UI's real job is pushing towards a passphrase, which this
/// can't measure.
SyncPasswordVerdict checkSyncPassword(String password) {
  if (password.length < syncPasswordMinLength) {
    return SyncPasswordVerdict.tooShort;
  }
  final lower = password.toLowerCase();
  if (_commonPasswords.any(lower.contains)) return SyncPasswordVerdict.weak;
  if (RegExp(r'^\d+$').hasMatch(password)) return SyncPasswordVerdict.weak;
  if (password.split('').toSet().length <= 3) return SyncPasswordVerdict.weak;
  return SyncPasswordVerdict.ok;
}

const List<String> _commonPasswords = [
  'password',
  'qwerty',
  '123456',
  'iloveyou',
  'admin',
  'letmein',
];

/// Runs Argon2id off the UI isolate.
///
/// It is meant to be slow — that slowness is what protects a stolen database — so on
/// the main isolate it would freeze the window for as long as it runs.
Future<List<int>> _deriveKek({
  required String password,
  required List<int> salt,
  required int memoryKib,
  required int iterations,
  required int parallelism,
}) {
  return Isolate.run(() async {
    final key = await Argon2id(
      memory: memoryKib,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: syncKeyLength,
    ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    return key.extractBytes();
  });
}

String _hex(List<int> bytes) {
  final out = StringBuffer();
  for (final byte in bytes) {
    out.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}
