/// Reading and writing one locator document over Firestore's REST API.
///
/// REST rather than the Firebase SDK, and that is the whole reason this is
/// cheap: no plugin, no `google-services.json`, no native build change on either
/// of the two apps that need it, and the same code path on macOS, Windows, Linux
/// and iOS.
///
/// **The HTTP itself is injected.** This library is pure Dart — the package's
/// rule, so the phone can depend on it — and the two apps hand in a `dart:io`
/// caller (`grid_pairing/locator_http_io.dart`). It also means every case below
/// is tested against a fake with no network in sight, which §8 requires.
///
/// Anonymous auth is not optional: the rules demand a signed-in caller so that
/// a stranger cannot spray the collection with REST calls. It costs one request
/// per launch and buys the only rate limit there is.
library;

import 'dart:convert';

import 'pair_token.dart';
import 'phone_locator.dart';
import 'locator_project.dart';

/// One HTTP request the locator needs made.
typedef LocatorCall = ({String method, Uri uri, String? body, String? idToken});

/// What came back. A transport that could not reach the server answers with a
/// status of 0 rather than throwing, so every failure below is one shape.
typedef LocatorReply = ({int status, String body});

/// How the locator's requests get made.
typedef LocatorSend = Future<LocatorReply> Function(LocatorCall call);

/// Why a locator call did not work, in words the screen can show as-is.
sealed class LocatorFailure {
  const LocatorFailure(this.message);

  /// Shown to a person, so never a status code or a stack trace.
  final String message;
}

/// The server could not be reached at all.
final class LocatorOffline extends LocatorFailure {
  const LocatorOffline()
    : super("Couldn't reach the internet. Check the connection and try again.");
}

/// The project refused the call — almost always rules that were never
/// published, which is a thing to fix here rather than something a user can act
/// on, so it says so plainly instead of blaming their network.
final class LocatorRefused extends LocatorFailure {
  const LocatorRefused()
    : super(
        'The address book for phones refused this computer. Grid needs its '
        'Firestore rules published — see docs/phone-link.md.',
      );
}

/// There is a record, and this token does not open it.
final class LocatorUnreadable extends LocatorFailure {
  const LocatorUnreadable()
    : super(
        "That code doesn't match what your computer published. Check you "
        'typed it right, or create a new one in Grid on the computer.',
      );
}

/// Anything else, including a version of the record this build cannot read.
final class LocatorBroken extends LocatorFailure {
  const LocatorBroken(super.message);
}

/// Reads and writes locator documents.
class LocatorClient {
  LocatorClient({
    required LocatorSend send,
    this.apiKey = kLocatorApiKey,
    this.projectId = kLocatorProjectId,
    this.collection = kLocatorCollection,
  }) : _send = send;

  /// The project's public web key.
  final String apiKey;

  /// Which Firebase project holds the collection.
  final String projectId;

  /// Which collection inside it.
  final String collection;

  final LocatorSend _send;

  /// The anonymous session, kept for as long as it lasts.
  ///
  /// Reused rather than re-signed-in per call: every sign-in creates an
  /// anonymous user on the project that never goes away, and a computer that
  /// republishes its address on every tunnel change would mint one each time.
  String? _idToken;

  /// Publishes [record] as the document [token] names.
  ///
  /// A full overwrite, and there is nothing to merge: the document holds one
  /// address, and the newest write is the only one that was ever true.
  Future<LocatorFailure?> publish(PairToken token, LocatorRecord record) async {
    final blob = sealLocatorRecord(record, token.locatorKey);
    if (blob.length > kLocatorMaxBlobCharacters) {
      return const LocatorBroken('That address is too long to publish.');
    }
    final body = jsonEncode({
      'fields': {
        'blob': {'stringValue': blob},
        'updatedAt': {'integerValue': '${record.publishedAtMs}'},
      },
    });
    return _authorised(
      (idToken) => (
        method: 'PATCH',
        uri: _document(token),
        body: body,
        idToken: idToken,
      ),
    ).then((result) => result.failure);
  }

  /// The record [token] points at.
  ///
  /// `(null, null)` means there is no document — a computer that has never
  /// published, or one whose phone was revoked. That is a normal state with its
  /// own sentence on screen, not an error.
  Future<(LocatorRecord?, LocatorFailure?)> read(PairToken token) async {
    final result = await _authorised(
      (idToken) =>
          (method: 'GET', uri: _document(token), body: null, idToken: idToken),
      missingIsEmpty: true,
    );
    if (result.failure != null) return (null, result.failure);
    final body = result.body;
    if (body == null) return (null, null);
    final blob = _blobIn(body);
    if (blob == null) return (null, null);
    final record = openLocatorRecord(blob, token.locatorKey);
    if (record == null) return (null, const LocatorUnreadable());
    return (record, null);
  }

  /// Forgets the document [token] names, so a revoked phone finds nothing
  /// rather than an address it can no longer use.
  ///
  /// Best effort by design: the phone has already been refused at the channel,
  /// and a failure to tidy up here must not stop the revoke.
  Future<LocatorFailure?> erase(PairToken token) => _authorised(
    (idToken) =>
        (method: 'DELETE', uri: _document(token), body: null, idToken: idToken),
    missingIsEmpty: true,
  ).then((result) => result.failure);

  Uri _document(PairToken token) => Uri.parse(
    'https://firestore.googleapis.com/v1/projects/$projectId'
    '/databases/(default)/documents/$collection/${token.locatorDocId}',
  );

  /// Makes [call] with a session, signing in first and once more if the session
  /// turns out to have expired.
  ///
  /// An id token lasts about an hour and a computer stays open for days, so the
  /// 401 path is the normal path rather than an edge case.
  Future<({Map<String, Object?>? body, LocatorFailure? failure})> _authorised(
    LocatorCall Function(String idToken) call, {
    bool missingIsEmpty = false,
  }) async {
    var token = _idToken;
    if (token == null) {
      final (fresh, failure) = await _signIn();
      if (failure != null) return (body: null, failure: failure);
      token = fresh!;
    }
    var reply = await _send(call(token));
    if (reply.status == 401) {
      _idToken = null;
      final (fresh, failure) = await _signIn();
      if (failure != null) return (body: null, failure: failure);
      reply = await _send(call(fresh!));
    }
    if (missingIsEmpty && reply.status == 404) {
      return (body: null, failure: null);
    }
    final failure = _failureOf(reply);
    if (failure != null) return (body: null, failure: failure);
    return (body: _decode(reply.body), failure: null);
  }

  Future<(String?, LocatorFailure?)> _signIn() async {
    final reply = await _send((
      method: 'POST',
      uri: Uri.parse(
        'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$apiKey',
      ),
      body: jsonEncode({'returnSecureToken': true}),
      idToken: null,
    ));
    final failure = _failureOf(reply);
    if (failure != null) return (null, failure);
    final idToken = _decode(reply.body)?['idToken'];
    if (idToken is! String || idToken.isEmpty) {
      // A 200 with no token happens when anonymous sign-in is switched off on
      // the project, and the message has to name that: nothing about the
      // network or the token the person typed is wrong.
      return (
        null,
        const LocatorBroken(
          'The address book for phones is not accepting new sessions. '
          "Anonymous sign-in is off on Grid's Firebase project.",
        ),
      );
    }
    _idToken = idToken;
    return (idToken, null);
  }

  LocatorFailure? _failureOf(LocatorReply reply) {
    if (reply.status >= 200 && reply.status < 300) return null;
    if (reply.status == 0) return const LocatorOffline();
    if (reply.status == 401 || reply.status == 403) {
      return const LocatorRefused();
    }
    return LocatorBroken(
      'The address book for phones answered ${reply.status}. '
      'Try again in a moment.',
    );
  }

  static Map<String, Object?>? _decode(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map<String, Object?> ? value : null;
    } on FormatException {
      return null;
    }
  }

  /// The sealed blob inside a Firestore document.
  ///
  /// Firestore labels every value with its type (`{"stringValue": "…"}`), so one
  /// layer comes off. A document with no `blob` reads as no record rather than
  /// as a failure: it is what a half-written row looks like, and the answer to
  /// both is the same.
  static String? _blobIn(Map<String, Object?> document) {
    final fields = document['fields'];
    if (fields is! Map) return null;
    final blob = fields['blob'];
    if (blob is! Map) return null;
    final value = blob['stringValue'];
    return value is String && value.isNotEmpty ? value : null;
  }
}
