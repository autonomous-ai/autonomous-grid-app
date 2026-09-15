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
import 'phone_chat_options.dart';
import 'phone_turns.dart';
import '../../../core/grid_paths.dart';
import '../../../infrastructure/pairing_host/mobile_upload_store.dart';
import '../../../infrastructure/pairing_host/phone_link_prefs.dart';

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
  final _prefs = const PhoneLinkPrefs();

  /// The relay this computer is registered with, kept so stopping can record
  /// *which* link was turned off — the connection holds it privately.
  String _cellUrl = '';

  DeviceRegistry get _registry => ref.read(deviceRegistryProvider);

  @override
  PhonePairingState build() {
    ref.onDispose(() {
      _disposed = true;
      unawaited(_connection?.stop());
    });
    return const PhonePairingOff();
  }

  /// Starts again if somebody had this on when the app last closed.
  ///
  /// Only then. The file does not exist until a person connects, so a computer
  /// that has never shared with a phone announces nothing — this restores a
  /// choice rather than making one.
  ///
  /// A failure here is left in [PhonePairingFailed] and not retried: the relay
  /// being down at launch is a thing to show on the screen, not a thing to
  /// keep dialling in the background.
  Future<void> resume() async {
    if (state is! PhonePairingOff) return;
    final choice = await _prefs.read();
    if (choice == null || !choice.on) return;
    await start(choice.cellUrl);
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
          // A *resume*, not another invite. `pairing.renew` is the phone
          // asking for its way back in, and an invite dies with this session.
          renewInvite: (deviceId) => connection.mintResume(deviceId),
          // The seam where the phone reaches into the running app. The service
          // itself stays Flutter-free so `tool/` can run it; these two closures
          // are the only part that needs the window to exist.
          sendToChat: (chatId, text, files) =>
              startPhoneTurn(ref, chatId: chatId, text: text, files: files),
          chatIsBusy: (chatId) => phoneChatIsBusy(ref, chatId),
          chatStreaming: (chatId) => phoneChatStreaming(ref, chatId),
          readOptions: (chatId) => phoneChatOptions(ref, chatId),
          setOption: (chatId, field, value) => setPhoneChatOption(
            ref,
            chatId: chatId,
            field: field,
            value: value,
          ),
          createChat: (text, projectId, files) => startPhoneChat(
            ref,
            text: text,
            projectId: projectId,
            files: files,
          ),
          // Under the grid home, beside the other app-owned state, so it is
          // cleared by the same hand that clears everything else.
          uploads: MobileUploadStore(
            directory: Directory('${GridPaths.home.path}/app/phone-uploads'),
          ),
        ),
        onEvent: _record,
      );
      await connection.start();
      if (_disposed) {
        await connection.stop();
        return;
      }
      _connection = connection;
      _cellUrl = cellUrl.trim();
      // Written only once the relay has actually accepted this computer. A
      // failed attempt must not be remembered as a choice, or every launch
      // would re-dial a relay that was never reachable.
      await _prefs.writeOn(_cellUrl);
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
    // Remembered before the socket closes, so a crash between the two leaves
    // the file saying "off" rather than bringing the link back on next launch.
    await _prefs.writeOff(_cellUrl);
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
