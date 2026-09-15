// Drives a live pairing relay end to end, playing BOTH halves: the desktop
// that proves it owns a host id, and the phone that dials in with a pairing
// code. Between them it runs the real E2EE handshake from
// `lib/infrastructure/pairing/` — through the relay's splice, so every sealed
// byte crosses a process that cannot read it.
//
// It exists because the two halves ship separately and nothing in either
// repo's test suite can see the other. A desync here is a decrypt failure
// three layers from the mistake; this is how you find out in one command.
//
//   # in the CLI repo
//   python -m pairing_relay --port 8787
//
//   # here
//   dart run tool/pairing_relay_probe.dart
//
// Exits non-zero, loudly, on the first thing that disagrees.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:grid_pairing/grid_pairing.dart';

const _protocolVersion = 1;

Future<void> main(List<String> args) async {
  final relay = _argument(args, '--relay') ?? 'ws://127.0.0.1:8787';
  // Must match what the relay was started with: the origin is inside every
  // host proof, so `localhost` and `127.0.0.1` are two different relays.
  final origin = _argument(args, '--origin') ?? relay;
  try {
    await _run(relay: relay, origin: origin);
    _say('PASS', 'desktop and phone agreed on every byte, through the splice');
  } on Object catch (error, stack) {
    stderr.writeln('\nFAIL  $error\n$stack');
    exitCode = 1;
  }
}

Future<void> _run({required String relay, required String origin}) async {
  // --- the desktop registers -------------------------------------------------
  final desktopKeys = await E2eeKeyPair.generate();
  final hostId = deriveRelayHostId(desktopKeys.publicKey);
  _say('desktop', 'host id $hostId, derived from our own key');

  final control = await _Peer.connect('$relay/v1/host/control');
  await control.sendJson({
    'type': 'host-hello',
    'v': _protocolVersion,
    'relayHostId': hostId,
    'hostPublicKeyB64': base64.encode(desktopKeys.publicKey),
  });

  final challenge = RelayHostChallenge.fromJson(await control.nextJson());
  if (challenge == null) throw StateError('relay sent no usable challenge');
  final outcome = await answerRelayHostChallenge(
    challenge,
    hostKeyPair: desktopKeys,
    context: RelayHostProofContext(
      relayOrigin: origin,
      relayHostId: hostId,
      hostPublicKey: desktopKeys.publicKey,
    ),
    nowMs: DateTime.now().millisecondsSinceEpoch,
  );
  final proof = switch (outcome) {
    RelayHostProofAnswered(:final proofB64) => proofB64,
    RelayHostProofRefused(:final check) => throw StateError(
      'refused the relay challenge: $check '
      '(is the relay running with --origin $origin ?)',
    ),
  };
  await control.sendJson({
    'type': 'host-challenge-ack',
    'challengeId': challenge.challengeId,
    'proofB64': proof,
  });
  final ack = await control.nextJson();
  _expect(ack['type'] == 'host-hello-ack', 'expected host-hello-ack, got $ack');
  _say('desktop', 'proof accepted, generation ${ack['generation']}');

  // --- a pairing code --------------------------------------------------------
  await control.sendJson({
    'type': 'invite-create',
    'reqId': 'probe-1',
    'relayDeviceId': 'probe-phone',
  });
  final invite = await control.nextJson();
  _expect(
    invite['type'] == 'invite-created',
    'expected an invite, got $invite',
  );
  _say('desktop', 'minted a pairing code');

  // --- the phone dials in ----------------------------------------------------
  final phone = await _Peer.connect('$relay/v1/connect/$hostId');
  await phone.sendJson({
    'type': 'relay-auth',
    'v': _protocolVersion,
    'mode': 'connect',
    'credential': invite['inviteToken'],
  });

  final opened = await control.nextJson();
  _expect(opened['type'] == 'conn-open', 'expected conn-open, got $opened');
  _say('relay', 'asked the desktop to attach for ${opened['connId']}');

  final data = await _Peer.connect('$relay/v1/host/data/${opened['connId']}');
  await data.sendJson({
    'type': 'host-data-auth',
    'v': _protocolVersion,
    'connTicket': opened['connTicket'],
    'generation': ack['generation'],
  });

  final relayHello = await phone.nextJson();
  _expect(relayHello['ok'] == true, 'phone was refused: $relayHello');
  _say('relay', 'spliced; from here it is forwarding bytes it cannot read');

  // --- the two peers build a channel through it ------------------------------
  final sessions = await _handshakeThroughSplice(
    phone: phone,
    desktop: data,
    desktopKeys: desktopKeys,
    relayHostId: hostId,
  );
  await _exchange(phone: phone, desktop: data, sessions: sessions);

  await control.close();
  await phone.close();
  await data.close();
}

Future<(E2eeSession phone, E2eeSession desktop)> _handshakeThroughSplice({
  required _Peer phone,
  required _Peer desktop,
  required E2eeKeyPair desktopKeys,
  required String relayHostId,
}) async {
  final phoneKeys = await E2eeKeyPair.generate();
  // The relay path binds the host id into the transcript, so a handshake
  // captured here can never be replayed onto a LAN socket. Leaving it out is
  // what the first run of this probe did, and the library was right to refuse.
  final context = E2eeContext(
    protocol: 'grid-mobile-e2ee',
    transport: E2eeTransport.relay,
    relayHostId: relayHostId,
  );
  final hello = E2eeHello(
    clientPublicKey: phoneKeys.publicKey,
    clientNonce: randomE2eeNonce(),
    context: context,
  );
  await phone.sendJson(hello.toJson());

  // The desktop reads the hello out of the splice and answers.
  final heard = E2eeHello.fromJson(await desktop.nextJson());
  _expect(heard != null, 'the hello did not survive the splice');
  final ready = E2eeReady(
    desktopPublicKey: desktopKeys.publicKey,
    clientNonce: heard!.clientNonce,
    desktopNonce: randomE2eeNonce(),
    context: heard.context,
  );
  await desktop.sendJson(ready.toJson());

  final answer = E2eeReady.fromJson(await phone.nextJson());
  _expect(answer != null, 'the ready did not survive the splice');

  final phoneSide = E2eeHandshake.validate(hello: hello, ready: answer!);
  final desktopSide = E2eeHandshake.validate(hello: heard, ready: ready);
  _expect(
    phoneSide != null && desktopSide != null,
    'the handshake did not pair',
  );

  final phoneSchedule = deriveE2eeKeySchedule(
    sharedSecret: await phoneKeys.sharedSecretWith(answer.desktopPublicKey),
    transcript: encodeE2eeTranscript(phoneSide!),
    clientNonce: hello.clientNonce,
    desktopNonce: answer.desktopNonce,
  );
  final desktopSchedule = deriveE2eeKeySchedule(
    sharedSecret: await desktopKeys.sharedSecretWith(heard.clientPublicKey),
    transcript: encodeE2eeTranscript(desktopSide!),
    clientNonce: heard.clientNonce,
    desktopNonce: ready.desktopNonce,
  );
  _expect(
    base64.encode(phoneSchedule.sessionId) ==
        base64.encode(desktopSchedule.sessionId),
    'the two sides derived different sessions — the transcripts disagree',
  );
  _say(
    'e2ee',
    'both sides derived session ${base64.encode(phoneSchedule.sessionId).substring(0, 12)}...',
  );
  return (
    E2eeSession.mobile(phoneSchedule),
    E2eeSession.desktop(desktopSchedule),
  );
}

Future<void> _exchange({
  required _Peer phone,
  required _Peer desktop,
  required (E2eeSession, E2eeSession) sessions,
}) async {
  final (phoneSide, desktopSide) = sessions;

  const question = 'may toi dang chay gi the?';
  final sealed = phoneSide.sealText(question);
  _expect(!sealed.contains('chay'), 'the plaintext is visible on the wire');
  await phone.sendText(sealed);
  _expect(
    desktopSide.openText(await desktop.nextText()) == question,
    'the desktop could not open what the phone sealed',
  );
  _say(
    'e2ee',
    'phone -> desktop opened, and the relay carried only ciphertext',
  );

  const answer = 'hai engine, mot ban build';
  await desktop.sendText(desktopSide.sealText(answer));
  _expect(
    phoneSide.openText(await phone.nextText()) == answer,
    'the phone could not open what the desktop sealed',
  );
  _say('e2ee', 'desktop -> phone opened');

  // Binary rides the same counter, so a terminal chunk between two replies
  // must keep both sides in step.
  final chunk = Uint8List.fromList(List.generate(512, (i) => i & 0xff));
  await desktop.sendBytes(desktopSide.sealBinary(chunk));
  final received = phoneSide.openBinary(await phone.nextBytes());
  _expect(
    received != null && received.length == chunk.length,
    'a binary frame did not survive the splice',
  );
  _say('e2ee', 'a 512-byte binary frame crossed intact');
}

/// One WebSocket, read one message at a time.
///
/// A socket is a stream and this script needs a queue: every step here is
/// "send, then read the one reply". Written out rather than pulling in
/// `package:async` for `StreamQueue`, which is only a transitive dependency
/// here — a probe is the last place to start relying on one of those.
class _Peer {
  _Peer(this._socket) {
    _socket.listen(
      (message) {
        if (_waiting.isEmpty) {
          _buffered.add(message);
          return;
        }
        _waiting.removeAt(0).complete(message);
      },
      onDone: () => _failWaiting(StateError('the socket closed')),
      onError: _failWaiting,
    );
  }

  static Future<_Peer> connect(String url) async =>
      _Peer(await WebSocket.connect(url));

  final WebSocket _socket;
  final _buffered = <Object?>[];
  final _waiting = <Completer<Object?>>[];

  Future<void> sendJson(Map<String, Object?> value) async =>
      _socket.add(jsonEncode(value));

  Future<void> sendText(String value) async => _socket.add(value);

  Future<void> sendBytes(List<int> value) async => _socket.add(value);

  Future<Map<String, Object?>> nextJson() async =>
      jsonDecode(await nextText()) as Map<String, Object?>;

  Future<String> nextText() async {
    final message = await _next();
    if (message is! String) throw StateError('expected text, got $message');
    return message;
  }

  Future<Uint8List> nextBytes() async {
    final message = await _next();
    if (message is! List<int>) throw StateError('expected bytes');
    return Uint8List.fromList(message);
  }

  Future<Object?> _next() {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeAt(0));
    final completer = Completer<Object?>();
    _waiting.add(completer);
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError(
        'nothing arrived within 10s — is the relay running?',
      ),
    );
  }

  void _failWaiting(Object error) {
    for (final completer in _waiting) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _waiting.clear();
  }

  Future<void> close() async => _socket.close();
}

String? _argument(List<String> args, String name) {
  final index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _say(String who, String what) => stdout.writeln('  $who  $what');
