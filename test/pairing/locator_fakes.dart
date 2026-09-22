import 'dart:convert';

import 'package:grid_pairing/grid_pairing.dart';

/// Firestore and the token service, as far as a [LocatorClient] can tell.
///
/// A fake rather than a mock: it answers the way the real ones do — a labelled
/// value inside a `fields` map, a fresh id token per sign-in, 404 for a document
/// that was never written — so a change to what the client sends shows up as a
/// test that fails here rather than as a phone that cannot find a computer.
///
/// Shared by the two files that need it. One copy, because a fake that drifts
/// from the real wire in one file and not the other is worse than no fake.
class FakeLocatorTransport {
  /// Every call made, in order, including the sign-ins.
  final calls = <LocatorCall>[];

  /// The documents that exist, by id.
  final documents = <String, String>{};

  /// The status every authorised call answers with. 200 means "behave".
  int status = 200;

  /// Whether the first authorised call answers 401, as an expired session does.
  var expireFirstCall = false;

  var _signIns = 0;
  var _authorised = 0;

  /// How many times this fake was signed in to.
  int get signIns => _signIns;

  /// The transport to hand [LocatorClient].
  Future<LocatorReply> send(LocatorCall call) async {
    calls.add(call);
    if (call.uri.path.contains('signUp')) {
      _signIns++;
      return (status: 200, body: jsonEncode({'idToken': 'id-token-$_signIns'}));
    }
    _authorised++;
    if (expireFirstCall && _authorised == 1) return (status: 401, body: '');
    if (status != 200) return (status: status, body: '');
    final id = call.uri.pathSegments.last;
    return switch (call.method) {
      'PATCH' => _write(id, call.body),
      'DELETE' => _delete(id),
      _ => _read(id),
    };
  }

  /// The record published for [token], read back the way the phone reads it.
  ///
  /// Goes through the real seal, so a test asserting on this is asserting that
  /// the phone would have found exactly this.
  LocatorRecord? recordFor(PairToken token) {
    final blob = documents[token.locatorDocId];
    return blob == null ? null : openLocatorRecord(blob, token.locatorKey);
  }

  /// Puts a record where [token] will look for it.
  void give(PairToken token, LocatorRecord record) =>
      documents[token.locatorDocId] = sealLocatorRecord(
        record,
        token.locatorKey,
      );

  LocatorReply _write(String id, String? body) {
    final fields = _fieldsIn(body);
    final blob = fields?['blob'];
    if (blob is! Map || blob['stringValue'] is! String) {
      return (status: 400, body: '');
    }
    documents[id] = blob['stringValue']! as String;
    return (status: 200, body: '{}');
  }

  LocatorReply _delete(String id) {
    final existed = documents.remove(id) != null;
    return existed ? (status: 200, body: '{}') : (status: 404, body: '');
  }

  LocatorReply _read(String id) {
    final blob = documents[id];
    if (blob == null) return (status: 404, body: '');
    return (
      status: 200,
      body: jsonEncode({
        'fields': {
          'blob': {'stringValue': blob},
          'updatedAt': {'integerValue': '1'},
        },
      }),
    );
  }

  static Map<String, Object?>? _fieldsIn(String? body) {
    if (body == null) return null;
    final value = jsonDecode(body);
    if (value is! Map<String, Object?>) return null;
    final fields = value['fields'];
    return fields is Map<String, Object?> ? fields : null;
  }
}
