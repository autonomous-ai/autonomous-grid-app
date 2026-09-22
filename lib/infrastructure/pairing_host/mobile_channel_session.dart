/// One phone, from the moment its socket reaches this computer.
///
/// Three stages, and each refuses to skip ahead:
///
/// 1. **Handshake.** The phone offers a key, this side answers, and both derive
///    the session. The phone already knows this computer's public key — it read
///    it from the sealed locator record — so whoever carries the bytes cannot
///    stand in the middle.
/// 2. **Authentication.** The handshake proves *this computer* to the phone;
///    nothing in it proves the phone. Its own connect code does that, and it is
///    sent here rather than on the opening frame precisely because here it is
///    unreadable to the tunnel.
/// 3. **Calls.** Sealed requests, answered from the allowlist.
///
/// **A frame that fails to open ends the session.** The counters are a strict
/// sequence, so once one frame is refused this side no longer knows where in
/// the stream it is, and carrying on would turn a gap into silent data loss.
library;

import 'dart:convert';
import 'dart:io';

import 'package:grid_pairing/grid_pairing.dart';

import 'device_registry.dart';
import 'mobile_rpc_service.dart';

enum _Stage { awaitingHello, awaitingAuth, serving }

/// Serves one phone until its socket closes.
class MobileChannelSession {
  MobileChannelSession({
    required WebSocket socket,
    required E2eeKeyPair hostKeyPair,
    required DeviceRegistry registry,
    required MobileRpcService rpc,
    required String relayHostId,
    required void Function(String message) onEvent,
    Stream<dynamic>? incoming,
  }) : _socket = socket,
       _incoming = incoming ?? socket,
       _hostKeyPair = hostKeyPair,
       _registry = registry,
       _rpc = rpc,
       _relayHostId = relayHostId,
       _onEvent = onEvent;

  final WebSocket _socket;

  /// What to read the phone's frames from, which is the socket itself unless a
  /// caller has already taken something off the front of it.
  ///
  /// The cell reads the phone's opening `relay-auth` frame before this session
  /// exists, so the session has never seen one. Handing the rest of the stream
  /// in keeps that true, rather than teaching this class about a frame that
  /// only exists one layer down.
  final Stream<dynamic> _incoming;
  final E2eeKeyPair _hostKeyPair;
  final DeviceRegistry _registry;
  final MobileRpcService _rpc;
  final String _relayHostId;
  final void Function(String message) _onEvent;

  _Stage _stage = _Stage.awaitingHello;
  E2eeSession? _session;
  PairedDevice? _device;

  /// Runs until the phone goes away or says something this side refuses.
  Future<void> serve() async {
    try {
      await for (final message in _incoming) {
        if (message is! String) {
          // Binary before there is anything to decode it with. Nothing in this
          // protocol sends bytes in the clear.
          await _refuse('a binary frame arrived in the clear');
          return;
        }
        final carryOn = await _accept(message);
        if (!carryOn) return;
      }
    } on Object catch (error) {
      _onEvent('phone session ended: $error');
    } finally {
      await _socket.close();
    }
  }

  Future<bool> _accept(String message) => switch (_stage) {
    _Stage.awaitingHello => _acceptHello(message),
    _Stage.awaitingAuth => _acceptAuth(message),
    _Stage.serving => _acceptCall(message),
  };

  Future<bool> _acceptHello(String message) async {
    final hello = E2eeHello.fromJson(_decode(message));
    if (hello == null) return _refuse('the opening message was not a hello');
    // The context is hashed into both transcripts, so a phone and this
    // computer that disagree about it simply derive different keys. Checking
    // it here turns that silent failure into a named one.
    if (hello.context.transport != E2eeTransport.relay ||
        hello.context.relayHostId != _relayHostId) {
      return _refuse('the phone dialled a different computer');
    }

    final ready = E2eeReady(
      desktopPublicKey: _hostKeyPair.publicKey,
      clientNonce: hello.clientNonce,
      desktopNonce: randomE2eeNonce(),
      context: hello.context,
    );
    final handshake = E2eeHandshake.validate(hello: hello, ready: ready);
    if (handshake == null) return _refuse('the handshake did not pair');

    _session = E2eeSession.desktop(
      deriveE2eeKeySchedule(
        sharedSecret: await _hostKeyPair.sharedSecretWith(
          hello.clientPublicKey,
        ),
        transcript: encodeE2eeTranscript(handshake),
        clientNonce: hello.clientNonce,
        desktopNonce: ready.desktopNonce,
      ),
    );
    _socket.add(jsonEncode(ready.toJson()));
    _stage = _Stage.awaitingAuth;
    return true;
  }

  Future<bool> _acceptAuth(String message) async {
    final session = _session!;
    final plaintext = session.openText(message);
    if (plaintext == null) {
      return _refuse('the first sealed frame did not open');
    }
    final auth = E2eeAuth.fromJson(_decode(plaintext));
    if (auth == null) {
      return _refuse('that was not an authentication');
    }
    if (auth.transcriptHashB64 !=
        base64.encode(session.schedule.transcriptHash)) {
      return _refuse('the phone derived a different handshake');
    }
    final device = await _registry.authenticate(auth.deviceToken);
    if (device == null) {
      // Deliberately not "unknown token" vs "revoked token": both are the same
      // answer to whoever is holding it, and the difference is only useful to
      // someone who should not be here.
      return _refuse('that phone is not paired with this computer');
    }

    _device = device;
    await _registry.markSeen(device.deviceId);
    _send(E2eeAuthenticated(hostName: _rpc.hostName).toJson());
    _stage = _Stage.serving;
    _onEvent('${device.name} connected');
    return true;
  }

  Future<bool> _acceptCall(String message) async {
    final plaintext = _session!.openText(message);
    if (plaintext == null) return _refuse('a sealed frame did not open');
    final request = MobileRpcRequest.fromJson(_decode(plaintext));
    if (request == null) return _refuse('that was not a request');
    final device = _device!;
    _send(
      (await _rpc.handle(
        request,
        mayAct: () => _mayActNow(device.deviceId),
      )).toJson(),
    );
    return true;
  }

  /// Whether this phone is allowed to make the computer act, **right now**.
  ///
  /// Re-read from the registry rather than taken from the record cached at
  /// authentication: turning the switch off at the computer has to reach a
  /// phone that is connected at that moment, and a session can stay open for
  /// hours. It costs one read of a small file, and only on the calls that act.
  ///
  /// A device that has since been revoked reads as not allowed, which is the
  /// same answer as never having been granted.
  Future<bool> _mayActNow(String deviceId) async {
    for (final device in await _registry.load()) {
      if (device.deviceId == deviceId) return device.mayAct;
    }
    return false;
  }

  void _send(Map<String, Object?> message) =>
      _socket.add(_session!.sealText(jsonEncode(message)));

  Object? _decode(String message) {
    try {
      return jsonDecode(message);
    } on FormatException {
      return null;
    }
  }

  Future<bool> _refuse(String because) async {
    _onEvent('refused ${_device?.name ?? 'a phone'}: $because');
    await _socket.close(WebSocketStatus.policyViolation, 'refused');
    return false;
  }
}
