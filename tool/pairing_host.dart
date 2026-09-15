// Runs this computer's half of the phone link against a relay, and prints a
// pairing code for one phone.
//
// It is the real thing, not a simulation: the identity it proves with is the
// one in ~/.grid/app/pairing_identity.json, the device token it issues goes
// into ~/.grid/app/paired_devices.json, and the grids it serves are read from
// the real ~/.grid/credentials.toml.
//
//   # in the CLI repo
//   python -m pairing_relay --port 8787
//
//   # here
//   dart run tool/pairing_host.dart
//
// Wiring this into the desktop UI — a pairing screen with a QR — is the piece
// that is still missing; until then this is how a phone gets a code.
import 'dart:io';

import 'package:grid_app/infrastructure/pairing_host/device_registry.dart';
import 'package:grid_app/infrastructure/pairing_host/host_identity_store.dart';
import 'package:grid_app/infrastructure/pairing_host/mobile_rpc_service.dart';
import 'package:grid_app/infrastructure/pairing_host/relay_host_connection.dart';
import 'package:grid_pairing/grid_pairing.dart';

Future<void> main(List<String> args) async {
  final cellUrl = _argument(args, '--relay') ?? 'ws://127.0.0.1:8787';
  final deviceName = _argument(args, '--device') ?? 'iPhone simulator';
  final hostName = _argument(args, '--name') ?? Platform.localHostname;

  final keyPair = await const HostIdentityStore().loadOrCreate();
  final registry = DeviceRegistry();
  // `late final` so the service can hand the phone a fresh pairing code: the
  // two genuinely do refer to each other, and the closure resolves the
  // connection only when a phone actually asks.
  late final RelayHostConnection connection;
  connection = RelayHostConnection(
    cellUrl: cellUrl,
    keyPair: keyPair,
    registry: registry,
    rpc: MobileRpcService(
      hostName: hostName,
      appVersion: '0.2.0',
      renewInvite: (deviceId) => connection.mintInvite(deviceId),
    ),
    onEvent: (message) => stdout.writeln('  host  $message'),
  );

  await connection.start();

  // A code is one device's worth of authority, so it gets its own token. Pair
  // the same phone twice and it holds two, which is correct: revoking one
  // leaves the other, and that is what "revoke this device" has to mean.
  final device = await registry.register(deviceName);
  final offer = PairingOffer(
    deviceToken: device.token,
    hostPublicKey: keyPair.publicKey,
    hostName: hostName,
    relay: await connection.mintInvite(device.deviceId),
  );

  stdout.writeln(
    '\n  Pairing code for "$deviceName" — expires in 10 minutes:\n',
  );
  stdout.writeln(offer.toLink());
  stdout.writeln('\n  Waiting for the phone. Ctrl-C to stop.\n');

  await ProcessSignal.sigint.watch().first;
  await connection.stop();
}

String? _argument(List<String> args, String name) {
  final index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}
