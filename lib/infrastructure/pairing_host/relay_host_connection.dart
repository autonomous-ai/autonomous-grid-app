/// This computer's long-lived connection to a pairing relay.
///
/// The desktop **dials out**. It never listens, which is the entire reason a
/// relay exists: a laptop behind a home router cannot accept a connection from
/// a phone on a mobile network, and neither can the phone. Both dial the same
/// third place and it joins them.
///
/// One control socket carries the whole relationship — the proof of who this
/// computer is, the pairing codes it mints, and the relay's requests to attach.
/// Each phone that arrives gets its **own** data socket, opened in response to
/// a `conn-open`, so one phone's traffic can never stall another's.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grid_pairing/grid_pairing.dart';

import 'device_registry.dart';
import 'mobile_channel_session.dart';
import 'mobile_rpc_service.dart';

const _protocolVersion = 1;
const _connectTimeout = Duration(seconds: 15);

/// A live registration with one relay cell.
class RelayHostConnection {
  RelayHostConnection({
    required String cellUrl,
    required E2eeKeyPair keyPair,
    required DeviceRegistry registry,
    required MobileRpcService rpc,
    required void Function(String message) onEvent,
  }) : _cellUrl = cellUrl,
       _keyPair = keyPair,
       _registry = registry,
       _rpc = rpc,
       _onEvent = onEvent,
       relayHostId = deriveRelayHostId(keyPair.publicKey);

  /// The id this computer's key owns. Also the path a phone dials.
  final String relayHostId;

  final String _cellUrl;
  final E2eeKeyPair _keyPair;
  final DeviceRegistry _registry;
  final MobileRpcService _rpc;
  final void Function(String message) _onEvent;

  WebSocket? _control;
  int _generation = 0;
  var _inviteCounter = 0;
  final _pendingInvites = <String, Completer<Map<String, Object?>>>{};
  Completer<void>? _registered;

  /// Registers with the relay and stays connected.
  ///
  /// Returns once the relay has accepted this computer's proof — before that
  /// there is no id to hand a phone, so a pairing code minted earlier would
  /// name a host the relay has never heard of.
  Future<void> start() async {
    final socket = await WebSocket.connect('$_cellUrl/v1/host/control');
    _control = socket;
    final registered = Completer<void>();
    _registered = registered;
    socket.listen(
      _onControlMessage,
      onDone: () => _fail(StateError('the relay closed the control channel')),
      onError: _fail,
      cancelOnError: true,
    );
    socket.add(
      jsonEncode({
        'type': 'host-hello',
        'v': _protocolVersion,
        'relayHostId': relayHostId,
        'hostPublicKeyB64': base64.encode(_keyPair.publicKey),
      }),
    );
    await registered.future.timeout(
      _connectTimeout,
      onTimeout: () => throw StateError('the relay did not answer in time'),
    );
  }

  /// A fresh pairing code's relay half, tied to [relayDeviceId].
  Future<PairingRelayEndpoint> mintInvite(String relayDeviceId) async {
    final socket = _control;
    if (socket == null) throw StateError('not registered with a relay');
    final reqId = 'invite-${++_inviteCounter}';
    final pending = Completer<Map<String, Object?>>();
    _pendingInvites[reqId] = pending;
    socket.add(
      jsonEncode({
        'type': 'invite-create',
        'reqId': reqId,
        'relayDeviceId': relayDeviceId,
      }),
    );
    final created = await pending.future.timeout(
      _connectTimeout,
      onTimeout: () {
        _pendingInvites.remove(reqId);
        throw StateError('the relay did not mint a pairing code in time');
      },
    );
    return PairingRelayEndpoint(
      cellUrl: _cellUrl,
      relayHostId: relayHostId,
      inviteToken: created['inviteToken']! as String,
      inviteExpiresAtMs: created['expiresAt']! as int,
    );
  }

  /// Drops the control channel. Phones already spliced are dropped with it.
  Future<void> stop() async {
    final socket = _control;
    _control = null;
    await socket?.close();
  }

  void _onControlMessage(Object? message) {
    if (message is! String) return;
    final Object? value;
    try {
      value = jsonDecode(message);
    } on FormatException {
      return;
    }
    if (value is! Map<String, Object?>) return;
    switch (value['type']) {
      case 'host-challenge':
        unawaited(_answerChallenge(value));
      case 'host-hello-ack':
        _generation = value['generation'] as int? ?? 0;
        _onEvent('registered with the relay as $relayHostId');
        _registered?.complete();
      case 'ping':
        _control?.add(jsonEncode({'type': 'pong', 't': value['t']}));
      case 'invite-created':
        _pendingInvites.remove(value['reqId'])?.complete(value);
      case 'conn-open':
        unawaited(_attach(value));
      default:
        // An unrecognised control frame is dropped, not fatal. Self-closing on
        // one stray message is how a relay session gets orphaned and every
        // phone is answered "host offline" until it is noticed.
        _onEvent('ignoring control frame ${value['type']}');
    }
  }

  Future<void> _answerChallenge(Map<String, Object?> value) async {
    final challenge = RelayHostChallenge.fromJson(value);
    if (challenge == null) return _fail(StateError('unreadable challenge'));
    final outcome = await answerRelayHostChallenge(
      challenge,
      hostKeyPair: _keyPair,
      context: RelayHostProofContext(
        relayOrigin: _cellUrl,
        relayHostId: relayHostId,
        hostPublicKey: _keyPair.publicKey,
      ),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    switch (outcome) {
      case RelayHostProofAnswered(:final proofB64):
        _control?.add(
          jsonEncode({
            'type': 'host-challenge-ack',
            'challengeId': challenge.challengeId,
            'proofB64': proofB64,
          }),
        );
      case RelayHostProofRefused(:final check):
        // Refusing is the feature: a relay that cannot produce a transcript
        // naming this origin and this id does not get an answer from us.
        _fail(StateError('refused the relay challenge: $check'));
    }
  }

  Future<void> _attach(Map<String, Object?> value) async {
    final connId = value['connId'];
    final ticket = value['connTicket'];
    if (connId is! String || ticket is! String) return;
    try {
      final socket = await WebSocket.connect(
        '$_cellUrl/v1/host/data/${Uri.encodeComponent(connId)}',
      );
      socket.add(
        jsonEncode({
          'type': 'host-data-auth',
          'v': _protocolVersion,
          'connTicket': ticket,
          'generation': _generation,
        }),
      );
      await MobileChannelSession(
        socket: socket,
        hostKeyPair: _keyPair,
        registry: _registry,
        rpc: _rpc,
        relayHostId: relayHostId,
        onEvent: _onEvent,
      ).serve();
    } on Object catch (error) {
      // One phone failing to attach is not a reason to drop the others.
      _onEvent('could not attach a phone: $error');
    }
  }

  void _fail(Object error) {
    final registered = _registered;
    _registered = null;
    if (registered != null && !registered.isCompleted) {
      registered.completeError(error);
      return;
    }
    _onEvent('relay connection lost: $error');
  }
}
