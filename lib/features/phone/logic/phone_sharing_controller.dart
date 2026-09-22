/// Sharing this computer with a phone: the server it runs, the public address it
/// opens, and the codes it hands out.
///
/// Three things have to be true at once for a phone to get through, and this is
/// the only place that knows it:
///
/// 1. a server is listening on loopback (`LocalPairingCell`),
/// 2. a tunnel is in front of it, giving it an address on the internet,
/// 3. that address is published, sealed, where each paired phone can read it.
///
/// Lose any one and the phone says "can't reach your computer", so they are
/// started together, torn down together, and re-established together when the
/// tunnel moves — which a quick tunnel does every time it opens.
///
/// **It starts when the app does, but only if somebody switched it on.** The
/// gateway pattern (`TelegramBotScope`): a link a person turned on keeps working
/// without them opening a screen to say so again, and a computer that never
/// turned it on opens nothing. That distinction is the whole of the consent
/// story here — this opens a door onto the machine that anyone on the internet
/// can knock on, and it must never be opened because an app happened to launch.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_pairing/grid_pairing.dart';
import 'package:grid_pairing/locator_http_io.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/pairing_host/cloudflared_tunnel.dart';
import '../../../infrastructure/pairing_host/device_registry.dart';
import '../../../infrastructure/pairing_host/host_identity_store.dart';
import '../../../infrastructure/pairing_host/local_pairing_cell.dart';
import '../../../infrastructure/pairing_host/phone_link_prefs.dart';
import '../../../shared/app_info.dart';
import 'phone_locator_publisher.dart';
import 'phone_rpc_wiring.dart';
import 'phone_sharing_state.dart';
import 'phone_tunnel_controller.dart';

/// How many event lines the screen keeps. Enough to watch a phone arrive and
/// see what happened next; not a log file.
const _maxEvents = 40;

/// How many times a tunnel that dropped is reopened before giving up.
///
/// Cloudflare offers quick tunnels with no uptime guarantee, so one dying is
/// expected and worth retrying. Three is where retrying stops being recovery
/// and starts being a loop nobody asked for.
const _maxTunnelAttempts = 3;

/// How long a tunnel has to have been up for its death to count as a fresh
/// incident rather than another go at the same one.
///
/// Without this the counter is either useless or fatal: reset it on every
/// success and a tunnel that flaps loops forever; never reset it and a computer
/// left open for a week stops sharing on the third drop, hours apart, with a
/// message about something that keeps closing when it does not.
const _incidentWindow = Duration(minutes: 5);

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

/// Whether sharing was on last time. Injectable for the same reason.
final phoneLinkPrefsProvider = Provider<PhoneLinkPrefs>(
  (ref) => const PhoneLinkPrefs(),
);

/// The locator this computer publishes its address to.
///
/// The HTTP client is pooled and closed with the provider: a computer
/// republishing an address opens the same two connections over and over.
final locatorClientProvider = Provider<LocatorClient>((ref) {
  final http = LocatorHttp();
  ref.onDispose(http.close);
  return LocatorClient(send: http.send);
});

/// Drives the Phone screen, and the sharing behind it.
final phoneSharingProvider =
    NotifierProvider<PhoneSharingController, PhoneSharingState>(
      PhoneSharingController.new,
    );

/// Runs the server, the tunnel and the locator as one thing.
class PhoneSharingController extends Notifier<PhoneSharingState> {
  LocalPairingCell? _cell;
  PhoneLocatorPublisher? _publisher;
  E2eeKeyPair? _keyPair;

  /// The `wss://` spelling of the current address — the one a phone dials and
  /// the only one a record may carry. The screen holds the `https://` one, and
  /// the two are derived from each other rather than typed twice.
  String _origin = '';

  /// When the address that is up now came up, for [_incidentWindow].
  var _openedAtMs = 0;

  var _disposed = false;
  var _attempts = 0;

  DeviceRegistry get _registry => ref.read(deviceRegistryProvider);
  AppLog get _log => ref.read(appLogProvider);

  @override
  PhoneSharingState build() {
    ref.onDispose(() {
      _disposed = true;
      // Only the cell, and deliberately not through [_release]: reading a
      // provider while the container is being torn down throws, and the throw
      // lands *before* the port is closed — so the listening socket outlives the
      // app that owns it. The tunnel needs nothing from here either, because
      // [PhoneTunnelController] kills its own process when it is disposed,
      // which is now.
      final cell = _cell;
      _cell = null;
      unawaited(cell?.stop());
    });
    // A quick tunnel ending is the normal end of a quick tunnel, not an error
    // anybody caused. Watched here rather than inside `start` because it
    // happens hours later, long after the call that opened it returned.
    ref.listen(phoneTunnelProvider, (_, next) {
      if (next is TunnelFailed) unawaited(_recover(next));
    });
    return const PhoneSharingOff();
  }

  /// Starts sharing again if somebody had it on when the app last closed.
  ///
  /// A failure is left on screen and not retried: Cloudflare being unreachable
  /// at launch is a thing to show, not a thing to keep dialling in the
  /// background.
  Future<void> resume() async {
    if (state is! PhoneSharingOff) return;
    if (!await ref.read(phoneLinkPrefsProvider).isOn()) return;
    await start();
  }

  /// Starts the server, opens an address, and publishes it to every paired
  /// phone.
  Future<void> start() async {
    if (state is PhoneSharingStarting) return;
    state = const PhoneSharingStarting('Starting');
    try {
      final keyPair = await ref.read(hostIdentityStoreProvider).loadOrCreate();
      if (_disposed) return;
      _keyPair = keyPair;
      final version = await ref.read(appVersionProvider.future);
      if (_disposed) return;

      final cell = _cell = LocalPairingCell(
        keyPair: keyPair,
        registry: _registry,
        rpc: buildPhoneRpcService(ref, appVersion: version),
        onEvent: _record,
      );
      await cell.start();
      if (_disposed) {
        await _release();
        return;
      }

      _publisher = PhoneLocatorPublisher(
        client: ref.read(locatorClientProvider),
        log: _log,
      );

      state = const PhoneSharingStarting('Opening an address for your phone');
      _attempts = 1;
      final tunnel = await _openTunnel(cell.port);
      if (_disposed) {
        await _release();
        return;
      }
      if (tunnel is! TunnelOpen) {
        await _release();
        state = PhoneSharingFailed(
          tunnel is TunnelFailed
              ? tunnel.message
              : 'Could not open an address for your phone.',
        );
        return;
      }

      _remember(tunnel);
      state = PhoneSharingLive(
        relayHostId: cell.relayHostId,
        publicUrl: tunnel.url,
        devices: await _registry.load(),
        events: const [],
      );
      // Written only once there is something for a phone to reach. A failed
      // attempt must not be remembered as a choice, or every launch would
      // reopen a tunnel that was never going to come up.
      await ref.read(phoneLinkPrefsProvider).write(on: true);
      await _publish();
    } on HostIdentityUnreadable catch (error) {
      // The one failure that must not be retried away: replacing the file would
      // un-pair every phone, so say so instead of offering a fix that is worse.
      await _release();
      state = PhoneSharingFailed('$error');
    } on Object catch (error) {
      _log.warn('phone', 'could not start sharing: $error');
      await _release();
      state = PhoneSharingFailed(
        'Could not start sharing with your phone: $error',
      );
    }
  }

  /// Adds a phone called [name] and returns with its code on screen.
  ///
  /// Each phone gets its own code, and that is the point: it names that phone's
  /// own locator document and is its own credential, so revoking one leaves the
  /// others working.
  Future<void> addPhone(String name) async {
    final live = state;
    if (live is! PhoneSharingLive || live.busy) return;
    state = live.copyWith(busy: true);
    try {
      final device = await _registry.register(
        name.trim().isEmpty ? 'My phone' : name.trim(),
        PairToken.generate(),
      );
      final problem = await _publisher?.publish(device, _currentRecord());
      _setLive(
        (current) => current.copyWith(
          busy: false,
          devices: [...current.devices, device],
          newest: problem == null ? device : null,
        ),
      );
      if (problem != null) _record(problem.message);
    } on Object catch (error) {
      _log.warn('phone', 'could not add a phone: $error');
      _record('Could not add that phone: $error');
      _setLive((current) => current.copyWith(busy: false));
    }
  }

  /// Lets [deviceId] send messages to the agents, or stops it.
  ///
  /// Off for every phone until this is called. A code proves which device is on
  /// the other end; it says nothing about who is holding it, and sending is the
  /// power to make this computer run an agent over its own files.
  Future<void> setMayAct(String deviceId, bool allowed) async {
    await _registry.setMayAct(deviceId, allowed);
    await _reloadDevices();
  }

  /// Revokes [deviceId]: its next request is refused, and the address it was
  /// reading is erased so it finds nothing rather than a door that is locked.
  Future<void> revoke(String deviceId) async {
    final devices = await _registry.load();
    final device = devices.where((d) => d.deviceId == deviceId).firstOrNull;
    await _registry.revoke(deviceId);
    await _reloadDevices();
    if (device != null) await _publisher?.erase(device);
  }

  /// Stops sharing. The address goes away with the tunnel, and phones already
  /// connected are dropped.
  Future<void> stop() async {
    // Remembered before anything closes, so a crash between the two leaves the
    // file saying "off" rather than reopening a tunnel on the next launch.
    await ref.read(phoneLinkPrefsProvider).write(on: false);
    await _release();
    if (!_disposed) state = const PhoneSharingOff();
  }

  /// The tunnel dropped. Reopen it and republish, or say so and stop.
  ///
  /// The stored choice is left **on**: somebody who switched sharing on still
  /// wants it on, and Cloudflare dropping a tunnel is not them changing their
  /// mind.
  Future<void> _recover(TunnelFailed failed) async {
    if (_disposed || state is! PhoneSharingLive) return;
    final cell = _cell;
    if (cell == null || !cell.isListening) return;
    final upFor = DateTime.now().millisecondsSinceEpoch - _openedAtMs;
    if (upFor > _incidentWindow.inMilliseconds) _attempts = 0;
    if (_attempts >= _maxTunnelAttempts) {
      await _release();
      state = PhoneSharingFailed(
        'The address for your phone keeps closing. ${failed.message}',
      );
      return;
    }
    _attempts++;
    _record('the address closed; opening a new one');
    // A new tunnel is a new hostname, so nothing published before it is true
    // any more.
    _publisher?.forget();
    final tunnel = await _openTunnel(cell.port);
    if (_disposed) return;
    if (tunnel is! TunnelOpen) return;
    _remember(tunnel);
    _setLive((current) => current.copyWith(publicUrl: tunnel.url));
    await _publish();
  }

  Future<TunnelState> _openTunnel(int port) async {
    final tunnel = ref.read(phoneTunnelProvider.notifier);
    await tunnel.open(port);
    return ref.read(phoneTunnelProvider);
  }

  /// Keeps what the next record will say, and when it became true.
  void _remember(TunnelOpen tunnel) {
    _origin = tunnel.origin;
    _openedAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// Tells every paired phone where this computer is now.
  Future<void> _publish() async {
    final publisher = _publisher;
    if (publisher == null) return;
    final problem = await publisher.publishAll(
      await _registry.load(),
      _currentRecord(),
    );
    if (problem != null) _record(problem);
  }

  /// What the phones are told: where to dial, which computer to expect, and the
  /// key it will have to prove it holds.
  LocatorRecord _currentRecord() => LocatorRecord(
    cellUrl: _origin,
    relayHostId: deriveRelayHostId(_keyPair!.publicKey),
    hostPublicKey: _keyPair!.publicKey,
    hostName: Platform.localHostname,
    publishedAtMs: DateTime.now().millisecondsSinceEpoch,
  );

  Future<void> _release() async {
    _attempts = 0;
    _origin = '';
    _openedAtMs = 0;
    _publisher?.forget();
    _publisher = null;
    final cell = _cell;
    _cell = null;
    await ref.read(phoneTunnelProvider.notifier).close();
    await cell?.stop();
  }

  Future<void> _reloadDevices() async {
    final devices = await _registry.load();
    _setLive((current) => current.copyWith(devices: devices));
  }

  void _record(String message) {
    _log.info('phone', message);
    _setLive((current) {
      final events = [...current.events, message];
      return current.copyWith(
        events: events.length > _maxEvents
            ? events.sublist(events.length - _maxEvents)
            : events,
        newest: current.newest,
      );
    });
    // A phone arriving or being refused changes `lastSeen`, and the list on
    // screen is the only place that shows it.
    unawaited(_reloadDevices());
  }

  /// Applies [change] only while sharing is live and this controller is alive.
  ///
  /// Every caller here runs from a socket callback or after an `await`, so the
  /// screen may be long gone; without the guard those land on a disposed
  /// notifier and throw somewhere with no stack worth reading.
  void _setLive(PhoneSharingLive Function(PhoneSharingLive current) change) {
    if (_disposed) return;
    final current = state;
    if (current is! PhoneSharingLive) return;
    state = change(current);
  }
}
