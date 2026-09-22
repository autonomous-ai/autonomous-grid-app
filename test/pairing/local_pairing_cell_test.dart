import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing_host/device_registry.dart';
import 'package:grid_app/infrastructure/pairing_host/local_pairing_cell.dart';
import 'package:grid_app/infrastructure/pairing_host/mobile_rpc_service.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// The cell served over a real loopback socket and dialled the way the phone
/// dials it. Offline and deterministic — loopback is not the network, and this
/// is the only way to prove the wire the phone speaks is the wire this answers.
///
/// The first test here is the one that matters: the frames a phone sends and
/// expects, in order, against the real server. An earlier version of this cell
/// never sent `relay-hello ok` at all, and every test passed — because each of
/// them only checked a *refusal*, and a phone that is let in was never taken
/// through its next move.
void main() {
  late Directory home;
  late DeviceRegistry registry;
  late E2eeKeyPair hostKeys;
  late LocalPairingCell cell;
  late List<String> events;
  // Every socket this test opened. Closed in teardown: a dialled socket left
  // open keeps the cell's connection handler alive, and with it this file's
  // isolate — which shows up as *other* files timing out under load, not this
  // one failing.
  late List<WebSocket> dialled;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid-cell-');
    events = [];
    dialled = [];
    registry = DeviceRegistry(file: File('${home.path}/paired.json'));
    hostKeys = await E2eeKeyPair.generate();
    cell = LocalPairingCell(
      keyPair: hostKeys,
      registry: registry,
      rpc: MobileRpcService(hostName: 'This Mac', appVersion: '0.0.0-test'),
      onEvent: events.add,
      // Short enough to prove the deadline is there without waiting it out.
      authDeadline: const Duration(milliseconds: 120),
    );
    await cell.start();
  });

  tearDown(() async {
    for (final socket in dialled) {
      await socket.close();
    }
    await cell.stop();
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // The OS's problem now.
    }
  });

  /// Dial the cell the way a phone does.
  Future<_Frames> dial({String? hostId, Object? opening}) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${cell.port}/v1/connect/${hostId ?? cell.relayHostId}',
    );
    dialled.add(socket);
    final frames = _Frames(socket);
    socket.add(
      opening is String
          ? opening
          : jsonEncode({'type': 'relay-auth', 'v': 1, 'mode': 'connect'}),
    );
    return frames;
  }

  /// The `relay-hello` the cell answers with, admitted or refused.
  Future<Map<String, Object?>?> helloOn(_Frames frames) async {
    final message = await frames.next();
    if (message is! String) return null;
    final value = jsonDecode(message);
    return value is Map<String, Object?> && value['type'] == 'relay-hello'
        ? value
        : null;
  }

  test('a phone holding a code gets all the way through the opening — let in, '
      'sealed, and told which computer answered', () async {
    final token = PairToken.generate();
    await registry.register('My phone', token);
    final frames = await dial();

    expect((await helloOn(frames))?['ok'], isTrue);

    final keys = await E2eeKeyPair.generate();
    final hello = E2eeHello(
      clientPublicKey: keys.publicKey,
      clientNonce: randomE2eeNonce(),
      context: E2eeContext(
        protocol: E2eeSuite.grid.protocol,
        transport: E2eeTransport.relay,
        relayHostId: cell.relayHostId,
      ),
    );
    frames.send(jsonEncode(hello.toJson()));
    final ready = E2eeReady.fromJson(jsonDecode(await frames.next() as String));

    expect(ready, isNotNull);
    // The pin: what came back is the key the locator record would have carried.
    expect(ready!.desktopPublicKey, hostKeys.publicKey);

    final session = E2eeSession.mobile(
      deriveE2eeKeySchedule(
        sharedSecret: await keys.sharedSecretWith(ready.desktopPublicKey),
        transcript: encodeE2eeTranscript(
          E2eeHandshake.validate(hello: hello, ready: ready)!,
        ),
        clientNonce: hello.clientNonce,
        desktopNonce: ready.desktopNonce,
      ),
    );
    frames.send(
      session.sealText(
        jsonEncode(
          E2eeAuth(
            deviceToken: token.normalized,
            transcriptHashB64: base64.encode(session.schedule.transcriptHash),
          ).toJson(),
        ),
      ),
    );
    final authenticated = E2eeAuthenticated.fromJson(
      jsonDecode(session.openText(await frames.next() as String)!),
    );

    expect(authenticated?.hostName, 'This Mac');
    expect(events, contains('My phone connected'));
  });

  test(
    'a phone whose stored address belongs to another computer is refused in '
    'words, so it can say "try again" rather than "connection closed"',
    () async {
      final frames = await dial(hostId: 'AAAAAAAAAAAAAAAA');

      final refusal = await helloOn(frames);

      expect(refusal?['ok'], isFalse);
      expect(refusal?['code'], kCellUnknownHost);
    },
  );

  test(
    'a socket that opens and says nothing is dropped, because the address is '
    'public and a silent socket is something being served for free',
    () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${cell.port}/v1/connect/${cell.relayHostId}',
      );
      dialled.add(socket);
      final frames = _Frames(socket);

      expect((await helloOn(frames))?['ok'], isFalse);
    },
  );

  test('anything that is not the opening frame is refused before this computer '
      'spends a key exchange on it', () async {
    final frames = await dial(opening: jsonEncode({'type': 'hello-there'}));

    expect((await helloOn(frames))?['ok'], isFalse);
  });

  test('an unpaired phone is refused after the channel is sealed, never before '
      '— which is what keeps its code off the wire', () async {
    final frames = await dial();
    expect((await helloOn(frames))?['ok'], isTrue);

    final keys = await E2eeKeyPair.generate();
    final hello = E2eeHello(
      clientPublicKey: keys.publicKey,
      clientNonce: randomE2eeNonce(),
      context: E2eeContext(
        protocol: E2eeSuite.grid.protocol,
        transport: E2eeTransport.relay,
        relayHostId: cell.relayHostId,
      ),
    );
    frames.send(jsonEncode(hello.toJson()));
    final ready = E2eeReady.fromJson(
      jsonDecode(await frames.next() as String),
    )!;
    final session = E2eeSession.mobile(
      deriveE2eeKeySchedule(
        sharedSecret: await keys.sharedSecretWith(ready.desktopPublicKey),
        transcript: encodeE2eeTranscript(
          E2eeHandshake.validate(hello: hello, ready: ready)!,
        ),
        clientNonce: hello.clientNonce,
        desktopNonce: ready.desktopNonce,
      ),
    );
    frames.send(
      session.sealText(
        jsonEncode(
          E2eeAuth(
            deviceToken: PairToken.generate().normalized,
            transcriptHashB64: base64.encode(session.schedule.transcriptHash),
          ).toJson(),
        ),
      ),
    );

    // The socket closes rather than answering, and the reason names the phone
    // for the person at the computer — never for the caller.
    expect(await frames.closed, isTrue);
    expect(
      events,
      contains('refused a phone: that phone is not paired with this computer'),
    );
  });

  test('the number of sockets is capped, so somebody who found the address '
      'cannot hold this computer open indefinitely', () async {
    final held = <_Frames>[];
    for (var i = 0; i < kMaxPhoneSockets; i++) {
      held.add(await dial());
    }
    // Every one of those is admitted and waiting for a handshake.
    for (final frames in held) {
      expect((await helloOn(frames))?['ok'], isTrue);
    }

    final extra = await dial();

    expect((await helloOn(extra))?['ok'], isFalse);
    expect(
      (await helloOn(
        extra,
      ).timeout(const Duration(seconds: 1), onTimeout: () => null)),
      isNull,
    );
  });
}

/// The frames one dialled socket has sent, in order, with nothing dropped.
///
/// A socket read as a plain stream loses whatever arrives between two `await`s,
/// and every test here reads its frames one at a time — so they are queued, the
/// way the phone's own client queues them.
class _Frames {
  _Frames(this._socket) {
    _socket.listen(
      (data) {
        if (_waiting.isEmpty) {
          _inbox.add(data);
          return;
        }
        _waiting.removeAt(0).complete(data);
      },
      onDone: () {
        _done.complete(true);
        for (final waiter in _waiting) {
          if (!waiter.isCompleted) waiter.complete(null);
        }
        _waiting.clear();
      },
    );
  }

  final WebSocket _socket;
  final _inbox = <Object?>[];
  final _waiting = <Completer<Object?>>[];
  final _done = Completer<bool>();

  /// Whether the cell closed the socket, waited for rather than polled.
  Future<bool> get closed =>
      _done.future.timeout(const Duration(seconds: 2), onTimeout: () => false);

  void send(String frame) => _socket.add(frame);

  Future<Object?> next() {
    if (_inbox.isNotEmpty) return Future.value(_inbox.removeAt(0));
    final waiter = Completer<Object?>();
    _waiting.add(waiter);
    return waiter.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
  }
}
