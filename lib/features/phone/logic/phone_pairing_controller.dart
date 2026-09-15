/// Pairing a phone with this computer: the relay registration, the codes it
/// mints, and the devices that came back.
///
/// The connection is **started by hand, never on launch.** Registering with a
/// relay announces this computer to a server, and doing that because the app
/// happened to open is not a decision the app gets to make for somebody. The
/// screen is the consent.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_pairing/grid_pairing.dart';

import '../../../infrastructure/pairing_host/device_registry.dart';
import '../../../infrastructure/pairing_host/host_identity_store.dart';
import '../../../infrastructure/pairing_host/mobile_rpc_service.dart';
import '../../../infrastructure/pairing_host/relay_host_connection.dart';
import '../../../shared/app_info.dart';
import 'phone_turns.dart';

/// Where to find a relay cell, unless `GRID_PAIRING_RELAY` says otherwise.
///
/// A local cell by default because that is the only one that exists: the relay
/// is `pairing_relay/` in the CLI repo, run by hand. Read at runtime rather
/// than compiled in, so pointing at another one does not need a rebuild.
String get defaultPairingRelayUrl =>
    Platform.environment['GRID_PAIRING_RELAY'] ?? 'ws://127.0.0.1:8787';

/// How many event lines the screen keeps. Enough to see a phone arrive and
/// what happened next; not a log file.
const _maxEvents = 40;

/// Where pairing has got to.
sealed class PhonePairingState {
  const PhonePairingState();
}

/// Not registered with any relay. Nothing about this computer is announced.
final class PhonePairingOff extends PhonePairingState {
  const PhonePairingOff();
}

/// Registering.
final class PhonePairingStarting extends PhonePairingState {
  const PhonePairingStarting();
}

/// Registered, and ready to hand out codes.
final class PhonePairingLive extends PhonePairingState {
  const PhonePairingLive({
    required this.relayHostId,
    required this.devices,
    required this.events,
    this.offer,
    this.busy = false,
  });

  /// The id this computer's key owns — what a phone dials.
  final String relayHostId;

  /// Phones that have a token for this computer.
  final List<PairedDevice> devices;

  /// Recent activity, newest last.
  final List<String> events;

  /// The last code minted, if one has been.
  final PairingOffer? offer;

  /// Whether an action is in flight, so the screen can disable its buttons.
  final bool busy;

  /// A copy with the named fields replaced.
  PhonePairingLive copyWith({
    List<PairedDevice>? devices,
    List<String>? events,
    PairingOffer? offer,
    bool? busy,
  }) => PhonePairingLive(
    relayHostId: relayHostId,
    devices: devices ?? this.devices,
    events: events ?? this.events,
    offer: offer ?? this.offer,
    busy: busy ?? this.busy,
  );
}

/// It did not work, and the message says what to do.
final class PhonePairingFailed extends PhonePairingState {
  const PhonePairingFailed(this.message);

  /// Shown on screen as-is.
  final String message;
}

/// Where this computer's identity lives.
///
/// A provider rather than a constructor default so a test can point it at a
/// temp directory: §8 is explicit that nothing in the suite may touch the real
/// `~/.grid`, and this store writes a private key.
final hostIdentityStoreProvider = Provider<HostIdentityStore>(
  (ref) => const HostIdentityStore(),
);

/// Where the paired phones live. Injectable for the same reason.
final deviceRegistryProvider = Provider<DeviceRegistry>(
  (ref) => DeviceRegistry(),
);

/// Drives the pairing screen.
final phonePairingProvider =
    NotifierProvider<PhonePairingController, PhonePairingState>(
      PhonePairingController.new,
    );

/// Registers with a relay, mints codes, and revokes devices.
class PhonePairingController extends Notifier<PhonePairingState> {
  RelayHostConnection? _connection;
  var _disposed = false;

  DeviceRegistry get _registry => ref.read(deviceRegistryProvider);

  @override
  PhonePairingState build() {
    ref.onDispose(() {
      _disposed = true;
      unawaited(_connection?.stop());
    });
    return const PhonePairingOff();
  }

  /// Registers this computer with the relay at [cellUrl].
  Future<void> start(String cellUrl) async {
    if (state is PhonePairingStarting) return;
    state = const PhonePairingStarting();
    try {
      final keyPair = await ref.read(hostIdentityStoreProvider).loadOrCreate();
      final version = await ref.read(appVersionProvider.future);
      // `late final` because the two genuinely refer to each other: the service
      // hands a phone its next code, and only the connection can mint one.
      late final RelayHostConnection connection;
      connection = RelayHostConnection(
        cellUrl: cellUrl.trim(),
        keyPair: keyPair,
        registry: _registry,
        rpc: MobileRpcService(
          hostName: Platform.localHostname,
          appVersion: version,
          renewInvite: (deviceId) => connection.mintInvite(deviceId),
          // The seam where the phone reaches into the running app. The service
          // itself stays Flutter-free so `tool/` can run it; these two closures
          // are the only part that needs the window to exist.
          sendToChat: (chatId, text) =>
              startPhoneTurn(ref, chatId: chatId, text: text),
          chatIsBusy: (chatId) => phoneChatIsBusy(ref, chatId),
        ),
        onEvent: _record,
      );
      await connection.start();
      if (_disposed) {
        await connection.stop();
        return;
      }
      _connection = connection;
      state = PhonePairingLive(
        relayHostId: connection.relayHostId,
        devices: await _registry.load(),
        events: const [],
      );
    } on HostIdentityUnreadable catch (error) {
      // The one failure that must not be retried away: replacing the file would
      // un-pair every phone, so say so instead of offering a fix that is worse.
      state = PhonePairingFailed('$error');
    } on Object catch (error) {
      state = PhonePairingFailed(_friendlyStartError(cellUrl, error));
    }
  }

  /// Mints a code for a phone called [deviceName].
  Future<void> createCode(String deviceName) async {
    final live = state;
    final connection = _connection;
    if (live is! PhonePairingLive || connection == null || live.busy) return;
    state = live.copyWith(busy: true);
    try {
      // A code is one device's worth of authority, so each gets its own token.
      // Pair the same phone twice and it holds two, which is correct: revoking
      // one has to leave the other working.
      final device = await _registry.register(deviceName.trim());
      final relay = await connection.mintInvite(device.deviceId);
      final keyPair = await ref.read(hostIdentityStoreProvider).loadOrCreate();
      _setLive(
        (current) => current.copyWith(
          busy: false,
          offer: PairingOffer(
            deviceToken: device.token,
            hostPublicKey: keyPair.publicKey,
            hostName: Platform.localHostname,
            relay: relay,
          ),
        ),
      );
      await _reloadDevices();
    } on Object catch (error) {
      _record('Could not create a code: $error');
      _setLive((current) => current.copyWith(busy: false));
    }
  }

  /// Revokes [deviceId]. That phone stops working at its next request.
  /// Lets [deviceId] send messages to the agents, or stops it.
  ///
  /// Off for every phone until this is called. Pairing proves which device is
  /// on the other end; it says nothing about who is holding it, and sending is
  /// the power to make this computer run an agent over its own files.
  Future<void> setMayAct(String deviceId, bool allowed) async {
    await _registry.setMayAct(deviceId, allowed);
    await _reloadDevices();
  }

  Future<void> revoke(String deviceId) async {
    await _registry.revoke(deviceId);
    await _reloadDevices();
  }

  /// Unregisters from the relay. Phones already connected are dropped.
  Future<void> stop() async {
    final connection = _connection;
    _connection = null;
    await connection?.stop();
    if (!_disposed) state = const PhonePairingOff();
  }

  Future<void> _reloadDevices() async {
    final devices = await _registry.load();
    _setLive((current) => current.copyWith(devices: devices));
  }

  void _record(String message) {
    _setLive((current) {
      final events = [...current.events, message];
      return current.copyWith(
        events: events.length > _maxEvents
            ? events.sublist(events.length - _maxEvents)
            : events,
      );
    });
    // A phone arriving or being refused changes `lastSeen`, and the list on
    // screen is the only place that shows it.
    unawaited(_reloadDevices());
  }

  /// Applies [change] only while the link is live and this controller is alive.
  ///
  /// Every caller here runs from a socket callback or after an `await`, so the
  /// screen may be long gone; without the guard those land on a disposed
  /// notifier and throw somewhere with no stack worth reading.
  void _setLive(PhonePairingLive Function(PhonePairingLive current) change) {
    if (_disposed) return;
    final current = state;
    if (current is! PhonePairingLive) return;
    state = change(current);
  }

  String _friendlyStartError(String cellUrl, Object error) {
    if (error is SocketException || error is WebSocketException) {
      return "Couldn't reach a relay at $cellUrl. Start one there, then try "
          'again.';
    }
    if ('$error'.contains('refused the relay challenge')) {
      // Almost always the origin: the relay bakes the address it was started
      // with into every challenge, so `localhost` and `127.0.0.1` are two
      // different relays as far as the proof is concerned.
      return 'That relay would not accept this computer. It has to be running '
          'with the same address you typed here.';
    }
    return 'Could not register with the relay: $error';
  }
}
