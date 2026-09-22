/// The phone's end of the link: find the computer, build the sealed channel,
/// call it.
///
/// Three steps, and the middle one is the only one with a secret in it:
///
/// 1. **Find it.** The code names a document on the locator and unlocks it; what
///    is inside is where the computer is right now. Nothing is dialled until
///    that has been read, because the address is different every time the
///    computer starts.
/// 2. **Seal the channel.** The record also carries the computer's public key,
///    and [_requirePinnedKey] requires the other end of the socket to hold it.
/// 3. **Say who this phone is**, inside the seal and never outside it.
///
/// ## The one check everything rests on
///
/// Whoever carries the bytes — the tunnel, and whatever is between it and here —
/// can read and rewrite every byte of the handshake. What stops them standing in
/// the middle is step 2: the key was in a record only this phone's code could
/// open, so a key that arrives and does not match it is somebody else. Take that
/// comparison out and the rest of this file is theatre.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grid_pairing/grid_pairing.dart';

/// Why a connection did not happen, in words a person can act on.
class RelayPhoneFailure implements Exception {
  const RelayPhoneFailure(this.message, {this.needsNewCode = false});

  /// Shown on screen as-is, so it is never a stack trace.
  final String message;

  /// Whether the credential this phone holds is spent, so retrying cannot
  /// help.
  ///
  /// Without it the screen offers "Try again" for a state where trying again
  /// is guaranteed to fail — which is worse than no button, because it costs
  /// the person the time to find that out.
  final bool needsNewCode;

  @override
  String toString() => message;
}

/// A live connection to one computer.
class RelayPhoneClient {
  RelayPhoneClient._(this._socket, this._onLost);

  final WebSocket _socket;

  /// Told when the channel goes away on its own, which is the only way anyone
  /// finds out. A relay restart, a computer going to sleep and a network change
  /// all end the socket silently; without this the phone keeps a green dot and
  /// the word "Connected" over a link that is gone (§5).
  final void Function(String reason)? _onLost;
  final _inbox = <Object?>[];
  final _waiting = <Completer<Object?>>[];

  E2eeSession? _session;
  String _hostName = '';
  var _closed = false;

  /// What the computer calls itself. Empty until the channel is up.
  String get hostName => _hostName;

  /// Whether this connection is still usable.
  bool get isOpen => !_closed;

  /// Finds the computer [token] belongs to and returns once the channel is
  /// sealed and this phone has proved which device it is.
  static Future<RelayPhoneClient> connect(
    PairToken token, {
    required LocatorClient locator,
    void Function(String message)? onLog,
    void Function(String reason)? onLost,
  }) async {
    final log = onLog ?? (String _) {};
    log('Finding your computer');
    final record = await _find(token, locator);
    log('Connecting to ${record.hostName}');
    final url =
        '${record.cellUrl}/v1/connect/'
        '${Uri.encodeComponent(record.relayHostId)}';
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        url,
      ).timeout(const Duration(seconds: 10));
    } on Object {
      // The address was published, so the computer meant to be reachable here.
      // Either it has since gone, or this phone is the one that is offline; the
      // two are indistinguishable from here, so say both.
      throw const RelayPhoneFailure(
        "Couldn't reach your computer. Check you're online, and that Grid is "
        'open on it.',
      );
    }

    final client = RelayPhoneClient._(socket, onLost);
    socket.listen(
      client._deliver,
      onDone: () => client._abandon('The connection closed.'),
      onError: (Object _) => client._abandon('The connection dropped.'),
    );
    try {
      await client._open(token, record, log);
      return client;
    } on Object {
      await client.close();
      rethrow;
    }
  }

  /// Where the computer says it is, or why this phone cannot know.
  static Future<LocatorRecord> _find(
    PairToken token,
    LocatorClient locator,
  ) async {
    final (record, failure) = await locator.read(token);
    if (failure != null) {
      // A code that does not open the record is the one failure retrying cannot
      // fix; everything else is worth another go.
      throw RelayPhoneFailure(
        failure.message,
        needsNewCode: failure is LocatorUnreadable,
      );
    }
    if (record == null) {
      throw const RelayPhoneFailure(
        "Your computer isn't sharing right now. Open Grid on it — and if it is "
        'already open, switch on Settings ▸ Phone.',
      );
    }
    return record;
  }

  /// Calls [method] on the computer and returns what it sent back.
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (_closed) throw const RelayPhoneFailure('Not connected.');
    final id = 'm${DateTime.now().microsecondsSinceEpoch}';
    _sendSealed(
      MobileRpcRequest(id: id, method: method, params: params).toJson(),
    );
    final response = MobileRpcResponse.fromJson(await _receiveSealed());
    return switch (response) {
      MobileRpcOk(:final result) => result,
      MobileRpcFailed(:final message) => throw RelayPhoneFailure(message),
      null => throw const RelayPhoneFailure('Your computer sent nonsense.'),
    };
  }

  /// Hangs up.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _abandon('Disconnected.', onPurpose: true);
    await _socket.close();
  }

  // --- opening ---------------------------------------------------------------

  Future<void> _open(
    PairToken token,
    LocatorRecord record,
    void Function(String) log,
  ) async {
    // No credential in this frame, deliberately: whoever terminates TLS sees it,
    // and this phone's code is not something to hand them on every reconnect.
    // Who this phone is gets settled below, inside the seal.
    _socket.add(jsonEncode({'type': 'relay-auth', 'v': 1, 'mode': 'connect'}));
    _readRelayHello(await _receivePlain());

    final keys = await E2eeKeyPair.generate();
    final hello = E2eeHello(
      clientPublicKey: keys.publicKey,
      clientNonce: randomE2eeNonce(),
      context: E2eeContext(
        protocol: E2eeSuite.grid.protocol,
        transport: E2eeTransport.relay,
        relayHostId: record.relayHostId,
      ),
    );
    _socket.add(jsonEncode(hello.toJson()));

    final ready = E2eeReady.fromJson(await _receivePlain());
    if (ready == null) {
      throw const RelayPhoneFailure('Your computer answered with nonsense.');
    }
    _requirePinnedKey(record, ready);
    final handshake = E2eeHandshake.validate(hello: hello, ready: ready);
    if (handshake == null) {
      throw const RelayPhoneFailure("That answer didn't match what we asked.");
    }
    final session = E2eeSession.mobile(
      deriveE2eeKeySchedule(
        sharedSecret: await keys.sharedSecretWith(ready.desktopPublicKey),
        transcript: encodeE2eeTranscript(handshake),
        clientNonce: hello.clientNonce,
        desktopNonce: ready.desktopNonce,
      ),
    );
    _session = session;
    log('Channel sealed');

    _sendSealed(
      E2eeAuth(
        deviceToken: token.normalized,
        transcriptHashB64: base64.encode(session.schedule.transcriptHash),
      ).toJson(),
    );
    final acknowledged = E2eeAuthenticated.fromJson(await _receiveSealed());
    if (acknowledged == null) {
      throw const RelayPhoneFailure(
        'Your computer no longer recognises this phone. Pair it again.',
      );
    }
    _hostName = acknowledged.hostName;
    log('Connected to $_hostName');
  }

  /// What arrived must be what the sealed record promised.
  void _requirePinnedKey(LocatorRecord record, E2eeReady ready) {
    if (constantTimeEquals(ready.desktopPublicKey, record.hostPublicKey)) {
      return;
    }
    throw const RelayPhoneFailure(
      "This isn't your computer answering. Grid stopped before sending "
      "anything — and if it keeps happening, don't try again, and tell "
      'someone.',
    );
  }

  void _readRelayHello(Object? value) {
    if (value is! Map<String, Object?> || value['type'] != 'relay-hello') {
      throw const RelayPhoneFailure('The relay answered with nonsense.');
    }
    if (value['ok'] == true) return;
    throw RelayPhoneFailure(switch (value['code']) {
      // The address this phone read belongs to a different computer, which
      // means the record it read was written by one and answered by another.
      // Reconnecting re-reads it, so trying again is the whole fix.
      4404 => 'Your computer moved since this phone last looked. Try again.',
      _ => "Your computer didn't pick up. Try again in a moment.",
    });
  }

  // --- frames ----------------------------------------------------------------

  void _sendSealed(Map<String, Object?> message) =>
      _socket.add(_session!.sealText(jsonEncode(message)));

  Future<Object?> _receiveSealed() async {
    final frame = await _receive();
    if (frame is! String) {
      throw const RelayPhoneFailure('Your computer sent an unreadable reply.');
    }
    final plaintext = _session!.openText(frame);
    if (plaintext == null) {
      // Fatal by design: the counters are a sequence, so once one frame is
      // refused this phone no longer knows where in the stream it is.
      await close();
      throw const RelayPhoneFailure(
        'The secure channel broke. Reconnect to your computer.',
      );
    }
    return _decode(plaintext);
  }

  Future<Object?> _receivePlain() async {
    final message = await _receive();
    if (message is! String) {
      throw const RelayPhoneFailure('The relay sent an unreadable reply.');
    }
    return _decode(message);
  }

  Object? _decode(String message) {
    try {
      return jsonDecode(message);
    } on FormatException {
      throw const RelayPhoneFailure('That reply was not readable.');
    }
  }

  Future<Object?> _receive() {
    if (_inbox.isNotEmpty) return Future.value(_inbox.removeAt(0));
    final completer = Completer<Object?>();
    _waiting.add(completer);
    return completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw const RelayPhoneFailure(
        'Your computer stopped answering. Try again.',
      ),
    );
  }

  void _deliver(Object? message) {
    if (_waiting.isEmpty) {
      _inbox.add(message);
      return;
    }
    _waiting.removeAt(0).complete(message);
  }

  void _abandon(String why, {bool onPurpose = false}) {
    final wasOpen = !_closed;
    _closed = true;
    for (final completer in _waiting) {
      if (!completer.isCompleted) {
        completer.completeError(RelayPhoneFailure(why));
      }
    }
    _waiting.clear();
    // Only for a link that was up and went away by itself. Closing on purpose
    // is not news, and reporting it would make "Forget this computer" announce
    // a connection problem.
    if (wasOpen && !onPurpose) _onLost?.call(why);
  }
}
