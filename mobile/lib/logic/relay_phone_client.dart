/// The phone's end of the link: dial the relay, build the sealed channel, call
/// the computer.
///
/// ## The one check everything rests on
///
/// The relay can read and rewrite every byte of the handshake. What stops it
/// standing in the middle is that the pairing code already told this phone the
/// computer's public key, so [_requirePinnedKey] compares what arrived against
/// what was promised. Take that comparison out and the rest of this file is
/// theatre: a relay would offer its own key and both ends would encrypt to it.
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

  /// Dials [offer]'s relay and returns once the channel is sealed and this
  /// phone has proved which device it is.
  static Future<RelayPhoneClient> connect(
    PairingOffer offer, {
    void Function(String message)? onLog,
    void Function(String reason)? onLost,
  }) async {
    final log = onLog ?? (String _) {};
    final url =
        '${offer.relay.cellUrl}/v1/connect/'
        '${Uri.encodeComponent(offer.relay.relayHostId)}';
    log('Dialling the relay');
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        url,
      ).timeout(const Duration(seconds: 10));
    } on Object {
      throw const RelayPhoneFailure(
        "Couldn't reach the relay. Check you're online, then try again.",
      );
    }

    final client = RelayPhoneClient._(socket, onLost);
    socket.listen(
      client._deliver,
      onDone: () => client._abandon('The connection closed.'),
      onError: (Object _) => client._abandon('The connection dropped.'),
    );
    try {
      await client._open(offer, log);
      return client;
    } on Object {
      await client.close();
      rethrow;
    }
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

  Future<void> _open(PairingOffer offer, void Function(String) log) async {
    _socket.add(
      jsonEncode({
        'type': 'relay-auth',
        'v': 1,
        'mode': 'connect',
        'credential': offer.relay.inviteToken,
      }),
    );
    _readRelayHello(await _receivePlain());
    log('The relay found your computer');

    final keys = await E2eeKeyPair.generate();
    final hello = E2eeHello(
      clientPublicKey: keys.publicKey,
      clientNonce: randomE2eeNonce(),
      context: E2eeContext(
        protocol: E2eeSuite.grid.protocol,
        transport: E2eeTransport.relay,
        relayHostId: offer.relay.relayHostId,
      ),
    );
    _socket.add(jsonEncode(hello.toJson()));

    final ready = E2eeReady.fromJson(await _receivePlain());
    if (ready == null) {
      throw const RelayPhoneFailure('Your computer answered with nonsense.');
    }
    _requirePinnedKey(offer, ready);
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
        deviceToken: offer.deviceToken,
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

  /// What arrived must be what the pairing code promised.
  void _requirePinnedKey(PairingOffer offer, E2eeReady ready) {
    if (constantTimeEquals(ready.desktopPublicKey, offer.hostPublicKey)) return;
    throw const RelayPhoneFailure(
      "This isn't the computer you paired with. Pair again from Grid on the "
      "computer — and if it keeps happening, don't, and tell someone.",
    );
  }

  void _readRelayHello(Object? value) {
    if (value is! Map<String, Object?> || value['type'] != 'relay-hello') {
      throw const RelayPhoneFailure('The relay answered with nonsense.');
    }
    if (value['ok'] == true) return;
    final code = value['code'];
    throw RelayPhoneFailure(
      switch (code) {
        // The two codes that name a cause somebody can act on.
        4404 => 'Your computer is offline. Open Grid on it, then try again.',
        4408 => "Your computer is running but didn't pick up. Try again.",
        4401 =>
          'This pairing code was already used, or it expired. Create a new one '
              'in Grid on your computer.',
        _ => "The relay wouldn't connect you. Try again in a moment.",
      },
      // A spent credential is the one failure retrying cannot fix.
      needsNewCode: code == 4401,
    );
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
