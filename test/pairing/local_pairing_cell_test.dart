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
/// Every call here is the phone's own first move: the frame shapes come from
/// `pairing_relay/server.py:148`, which is the contract this replaces.
void main() {
  late Directory home;
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
    cell = LocalPairingCell(
      keyPair: await E2eeKeyPair.generate(),
      registry: DeviceRegistry(file: File('${home.path}/paired.json')),
      rpc: MobileRpcService(hostName: 'This Mac', appVersion: '0.0.0-test'),
      onEvent: events.add,
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

  /// Dial the cell the way a phone does, on [hostId] with [credential].
  Future<WebSocket> dial({String? hostId, required String credential}) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${cell.port}/v1/connect/${hostId ?? cell.relayHostId}',
    );
    dialled.add(socket);
    socket.add(
      jsonEncode({
        'type': 'relay-auth',
        'mode': 'connect',
        'credential': credential,
      }),
    );
    return socket;
  }

  /// The refusal a phone is told before the socket dies, or null if it was let
  /// in (or dropped without a word, which is the bug this distinguishes).
  Future<Map<String, Object?>?> refusalOn(WebSocket socket) async {
    await for (final message in socket) {
      if (message is! String) continue;
      final value = jsonDecode(message);
      if (value is Map<String, Object?> && value['type'] == 'relay-hello') {
        return value;
      }
      return null;
    }
    return null;
  }

  test('a code that was never minted is refused in words, not by a socket '
      'that simply dies — the phone has a sentence to show', () async {
    final socket = await dial(credential: 'never-minted');

    final refusal = await refusalOn(socket);

    expect(refusal, isNotNull);
    expect(refusal!['ok'], isFalse);
    expect(refusal['code'], kCellBadCredential);
  });

  test('a phone dialling a host id this computer does not own is told so, '
      'rather than being handed a session for somebody else', () async {
    cell.publicOrigin = 'wss://example.test';
    final endpoint = cell.mintInvite('phone-1');

    final socket = await dial(
      hostId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      credential: endpoint.inviteToken,
    );

    expect((await refusalOn(socket))?['code'], kCellUnknownHost);
  });

  test('a real pairing code gets past the door — it is not answered with a '
      'refusal, and the handshake is what comes next', () async {
    cell.publicOrigin = 'wss://example.test';
    final endpoint = cell.mintInvite('phone-1');

    final socket = await dial(credential: endpoint.inviteToken);
    // A hello this side will refuse, but only *after* the credential passed:
    // what is being proven here is that the door opened at all.
    socket.add(jsonEncode({'type': 'not-a-hello'}));

    expect(await refusalOn(socket), isNull);
    expect(events.any((e) => e.contains('refused')), isTrue);
  });

  test('the same code cannot be used twice, so a code somebody else also saw '
      'is spent by whoever got there first', () async {
    cell.publicOrigin = 'wss://example.test';
    final endpoint = cell.mintInvite('phone-1');

    await dial(credential: endpoint.inviteToken);
    final second = await dial(credential: endpoint.inviteToken);

    expect((await refusalOn(second))?['code'], kCellBadCredential);
  });

  test('minting refuses while there is no public address, because the code '
      'would carry loopback and on a phone that means the phone', () {
    expect(() => cell.mintInvite('phone-1'), throwsStateError);
  });

  test('a minted code carries the public address and this computer id, which '
      'is the whole of what the phone needs to dial', () {
    cell.publicOrigin = 'wss://tunnel.test';

    final endpoint = cell.mintInvite('phone-1');

    expect(endpoint.cellUrl, 'wss://tunnel.test');
    expect(endpoint.relayHostId, cell.relayHostId);
    expect(endpoint.inviteToken, isNotEmpty);
  });

  test('healthz answers, so whatever is fronting this can tell a cell that is '
      'up from a port that merely accepts', () async {
    final client = HttpClient();
    addTearDown(client.close);

    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${cell.port}/healthz'),
    );
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    expect(response.statusCode, HttpStatus.ok);
    expect((body as Map)['ok'], isTrue);
  });

  test('anything that is not a connect is a 404 — the cell serves one route '
      'and answering more would be a surface nobody asked for', () async {
    final client = HttpClient();
    addTearDown(client.close);

    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${cell.port}/v1/host/control'),
    );

    expect((await request.close()).statusCode, HttpStatus.notFound);
  });
}
