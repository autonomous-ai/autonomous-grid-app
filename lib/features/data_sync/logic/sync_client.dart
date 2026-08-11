import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sync_envelope.dart';
import 'sync_keyring.dart';

/// Talks to the control plane's `/v1/grid/app-sync/*` routes, and to the storage
/// bucket those routes point at.
///
/// Backups don't travel through Grid's API. The control plane authenticates the
/// session and hands back a short-lived signed URL; the payload goes straight
/// from this machine to cloud storage and back. So an upload is two calls and a
/// transfer — ask, PUT, commit — and the commit is where the server checks what
/// actually landed.
///
/// Everything it sends is already encrypted and everything it receives still is —
/// this layer moves bytes and maps failures to sentences a person can act on. It
/// never throws: each call answers with a value or a [SyncApiError], the same shape
/// `ManagedNetworkClient` uses.
class SyncClient {
  const SyncClient({required this.apiUrl, required this.sessionToken});

  /// The control-plane base URL, with or without a trailing slash.
  final String apiUrl;

  /// The `session_token` from `~/.grid/credentials.toml`.
  final String sessionToken;

  static const String _base = 'v1/grid/app-sync';

  /// Long enough for a slow upload of a 25 MB object on a poor connection, short
  /// enough that a dead connection doesn't leave a progress bar running all day.
  static const Duration _transferTimeout = Duration(minutes: 5);

  /// Every backup this account holds, newest first.
  ///
  /// A row this build cannot read is **skipped**, never fatal, and that is the
  /// forward-compatibility hinge rather than politeness: `SyncKeyBlob.decode`
  /// refuses a key record whose `kdf` it doesn't know, so the first backup
  /// written by a build with stronger parameters would otherwise take the whole
  /// list down on every older machine — including the older backups on it, which
  /// that machine can still open perfectly well.
  Future<(List<SyncVersion>?, SyncApiError?)> listVersions() async {
    final (body, error) = await _json('GET', _uri('snapshots'));
    if (error != null) return (null, error);
    final raw = body!['snapshots'];
    final versions = <SyncVersion>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map<String, Object?>) continue;
        try {
          final version = SyncVersion.fromJson(item);
          if (version != null) versions.add(version);
        } on SyncFormatException {
          // One unreadable row, not an unreadable list.
        }
      }
    }
    return (versions, null);
  }

  /// Uploads a sealed snapshot and returns the version number it became.
  ///
  /// Three steps, and the middle one doesn't touch Grid's API at all: the
  /// payload goes straight to cloud storage. The server reads the version's key,
  /// device name and media list back out of the payload's own header when it
  /// commits, so there is nothing else to send and nothing that could disagree
  /// with what was stored.
  Future<(int?, SyncApiError?)> putSnapshot(List<int> envelope) async {
    final (started, startError) = await _json(
      'POST',
      _uri('snapshot/upload-url'),
    );
    if (startError != null) return (null, startError);
    final uploadId = started!['upload_id'];
    final uploadUrl = started['upload_url'];
    if (uploadId is! String || uploadUrl is! String) {
      return (null, const SyncApiError("The server's answer wasn't readable."));
    }
    final uploadError = await _putToStorage(uploadUrl, envelope);
    if (uploadError != null) return (null, uploadError);

    final (committed, commitError) = await _json(
      'POST',
      _uri('snapshot/commit'),
      payload: utf8.encode(jsonEncode({'upload_id': uploadId})),
      contentType: 'application/json',
    );
    if (commitError != null) return (null, commitError);
    final version = committed!['version'];
    return (version is int ? version : null, null);
  }

  /// Downloads one backup's payload.
  Future<(Uint8List?, SyncApiError?)> getSnapshot(int version) async {
    final (body, error) = await _json(
      'GET',
      _uri('snapshot', query: {'version': '$version'}),
    );
    if (error != null) return (null, error);
    final url = body!['download_url'];
    if (url is! String) {
      return (null, const SyncApiError('That backup is no longer available.'));
    }
    return _getFromStorage(url);
  }

  /// Removes one backup. No password: see the route's own note — a password
  /// protects reading, and the version a user most wants gone is often the one
  /// whose password they've lost.
  Future<SyncApiError?> deleteVersion(int version) async {
    final (_, error) = await _send('DELETE', _uri('snapshot/$version'));
    return error;
  }

  /// Removes every backup this account has.
  Future<SyncApiError?> deleteEverything() async {
    final (_, error) = await _send('DELETE', _uri(''));
    return error;
  }

  /// Asks which media the server already holds, and where to put the rest.
  ///
  /// One call answers both, which is what keeps a second upload of an unchanged
  /// photo library free: whatever comes back in `have` is never transferred.
  Future<(SyncObjectPlan?, SyncApiError?)> checkObjects(
    List<String> oids,
  ) async {
    if (oids.isEmpty) {
      return ((have: <String>{}, upload: <String, String>{}), null);
    }
    final (body, error) = await _json(
      'POST',
      _uri('objects/check'),
      payload: utf8.encode(jsonEncode({'oids': oids})),
      contentType: 'application/json',
    );
    if (error != null) return (null, error);
    final have = body!['have'];
    final upload = body['upload'];
    return (
      (
        have: {
          if (have is List)
            for (final oid in have)
              if (oid is String) oid,
        },
        upload: {
          if (upload is Map<String, Object?>)
            for (final entry in upload.entries)
              if (entry.value is String) entry.key: entry.value as String,
        },
      ),
      null,
    );
  }

  /// Sends one media file to the URL [checkObjects] handed back.
  Future<SyncApiError?> putObject(String url, List<int> envelope) =>
      _putToStorage(url, envelope);

  /// Tells the server which media finished uploading, so it records them.
  ///
  /// Returns the ids it would not accept — never stored, or refused for size —
  /// so a snapshot is never committed claiming media that isn't there.
  Future<(List<String>?, SyncApiError?)> commitObjects(
    List<String> oids,
  ) async {
    if (oids.isEmpty) return (<String>[], null);
    final (body, error) = await _json(
      'POST',
      _uri('objects/commit'),
      payload: utf8.encode(jsonEncode({'oids': oids})),
      contentType: 'application/json',
    );
    if (error != null) return (null, error);
    return (
      [
        for (final key in ['missing', 'rejected'])
          if (body![key] is List)
            for (final oid in body[key] as List)
              if (oid is String) oid,
      ],
      null,
    );
  }

  /// Downloads one media file.
  Future<(Uint8List?, SyncApiError?)> getObject(String oid) async {
    final (body, error) = await _json('GET', _uri('objects/$oid'));
    if (error != null) return (null, error);
    final url = body!['download_url'];
    if (url is! String) {
      return (null, const SyncApiError('That file is no longer available.'));
    }
    return _getFromStorage(url);
  }

  /// A control-plane call that answers JSON.
  Future<(Map<String, Object?>?, SyncApiError?)> _json(
    String method,
    Uri uri, {
    List<int>? payload,
    String contentType = 'application/octet-stream',
  }) async {
    final (body, error) = await _send(
      method,
      uri,
      payload: payload,
      contentType: contentType,
    );
    if (error != null) return (null, error);
    if (body == null || body.isEmpty) return (const <String, Object?>{}, null);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on FormatException {
      return (null, const SyncApiError("The server's answer wasn't readable."));
    }
    if (decoded is! Map<String, Object?>) {
      return (null, const SyncApiError("The server's answer wasn't readable."));
    }
    return (decoded, null);
  }

  /// Sends a payload straight to cloud storage.
  ///
  /// No Grid session here — the URL *is* the authorisation, and it is good for
  /// one object for a few minutes. The content type must match what the server
  /// signed, or storage rejects the signature rather than the request.
  Future<SyncApiError?> _putToStorage(String url, List<int> payload) async {
    final (_, error) = await _send(
      'PUT',
      Uri.parse(url),
      payload: payload,
      authorized: false,
    );
    return error;
  }

  Future<(Uint8List?, SyncApiError?)> _getFromStorage(String url) =>
      _send('GET', Uri.parse(url), authorized: false);

  Uri _uri(String path, {Map<String, String>? query}) {
    final base = apiUrl.endsWith('/') ? apiUrl : '$apiUrl/';
    final tail = path.isEmpty ? _base : '$_base/$path';
    return Uri.parse('$base$tail').replace(queryParameters: query);
  }

  Future<(Uint8List?, SyncApiError?)> _send(
    String method,
    Uri uri, {
    List<int>? payload,
    String contentType = 'application/octet-stream',
    bool authorized = true,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.openUrl(method, uri);
      // Never send the Grid session to the storage host: it is a different
      // service, and a signed URL needs no bearer of ours to work.
      if (authorized) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $sessionToken',
        );
      }
      if (payload != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
        request.add(payload);
      }
      final response = await request.close().timeout(_transferTimeout);
      final body = await _collect(response);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return (body, null);
      }
      return (null, _errorFor(response.statusCode, body));
    } on SocketException {
      return (
        null,
        const SyncApiError(
          "Couldn't reach the sync service. Check your connection.",
        ),
      );
    } on HttpException catch (error) {
      return (null, SyncApiError('The transfer failed: ${error.message}'));
    } finally {
      client.close();
    }
  }

  Future<Uint8List> _collect(HttpClientResponse response) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in response) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// Maps a failed response to a sentence, keeping the raw body for the log.
  ///
  /// The two 413s are different problems with different fixes — one file is too
  /// big, or the whole backup is — so they must not collapse into one sentence.
  SyncApiError _errorFor(int status, Uint8List body) {
    final raw = utf8.decode(body, allowMalformed: true);
    final code = _errorCodeOf(raw);
    final message = switch (status) {
      401 => 'Your session has expired. Sign in again.',
      404 => 'That backup is no longer on the server.',
      413 when code == 'quota_exceeded' =>
        'Your cloud backup storage is full. Delete an older backup and try again.',
      413 => 'That file is too large to back up.',
      429 => "You've uploaded a lot in the last hour. Try again later.",
      >= 500 => 'The sync service is having trouble. Try again in a moment.',
      _ => 'The server refused the request (error $status).',
    };
    return SyncApiError(
      message,
      statusCode: status,
      body: raw,
      errorCode: code,
    );
  }

  String? _errorCodeOf(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return null;
      final detail = decoded['detail'];
      if (detail is Map<String, Object?> && detail['error_code'] is String) {
        return detail['error_code'] as String;
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

/// What the server already holds, and a one-off URL for each file it doesn't.
typedef SyncObjectPlan = ({Set<String> have, Map<String, String> upload});

/// A failed sync call: [message] is what the screen shows, the rest is what the
/// log keeps so a support conversation has something to work from.
class SyncApiError {
  const SyncApiError(
    this.message, {
    this.statusCode,
    this.body,
    this.errorCode,
  });

  final String message;
  final int? statusCode;
  final String? body;

  /// The machine-readable reason from the control plane (`quota_exceeded`,
  /// `too_large`, `rate_limited`, …), when it sent one.
  final String? errorCode;

  /// The log line: the sentence plus the raw body, clipped — a log that only
  /// repeats what the user just read diagnoses nothing.
  String get debugDetail {
    final raw = body?.trim();
    if (raw == null || raw.isEmpty || raw == message) return message;
    final clipped = raw.length > 800 ? '${raw.substring(0, 800)}…' : raw;
    return '$message\n$clipped';
  }
}

/// One backup as the list shows it, before any password has been typed.
class SyncVersion {
  const SyncVersion({
    required this.version,
    required this.keyBlob,
    required this.sizeBytes,
    required this.deviceLabel,
    required this.createdAt,
    required this.counts,
  });

  final int version;

  /// This version's key, wrapped in its own password — what the app unwraps to
  /// check the password the user types for *this* backup.
  final SyncKeyBlob keyBlob;

  final int sizeBytes;

  /// The machine that made it, as it named itself.
  final String deviceLabel;

  final DateTime createdAt;

  /// What's inside: `{"chats": 42, "media": 12}`.
  final Map<String, int> counts;

  int get chatCount => counts['chats'] ?? 0;

  /// The user's own reminder for this backup's password, if they left one.
  String? get hint => keyBlob.hint;

  static SyncVersion? fromJson(Map<String, Object?> json) {
    final version = json['version'];
    final keyBlob = json['key_blob'];
    if (version is! int || keyBlob is! String) return null;
    final counts = json['counts'];
    final createdAt = json['created_at'];
    return SyncVersion(
      version: version,
      keyBlob: SyncKeyBlob.decode(keyBlob),
      sizeBytes: json['size_bytes'] is int ? json['size_bytes'] as int : 0,
      deviceLabel: json['device_label'] is String
          ? json['device_label'] as String
          : 'Unknown computer',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (createdAt is int ? createdAt : 0) * 1000,
      ),
      counts: {
        if (counts is Map<String, Object?>)
          for (final entry in counts.entries)
            if (entry.value is int) entry.key: entry.value as int,
      },
    );
  }
}
