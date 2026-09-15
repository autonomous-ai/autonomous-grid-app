/// The one piece of state this app has: which computer it is talking to, and
/// how that is going.
///
/// A sealed type rather than a handful of booleans, so every screen has to say
/// what it shows in each case and "connected but also failed" cannot be built.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_pairing/grid_pairing.dart';

import 'paired_host_store.dart';
import 'relay_phone_client.dart';

/// One grid, as much of it as the computer is willing to say.
typedef GridRow = ({String id, String name, String type, String email});

/// Where the link has got to.
sealed class PhoneLinkState {
  const PhoneLinkState();
}

/// No computer paired yet.
final class PhoneLinkUnpaired extends PhoneLinkState {
  const PhoneLinkUnpaired();
}

/// Working on it, with something honest to show while it happens.
final class PhoneLinkConnecting extends PhoneLinkState {
  const PhoneLinkConnecting(this.step);

  /// What is being attempted right now.
  final String step;
}

/// Through, with what the computer said.
final class PhoneLinkConnected extends PhoneLinkState {
  const PhoneLinkConnected({
    required this.hostName,
    required this.platform,
    required this.appVersion,
    required this.grids,
  });

  /// What the computer calls itself.
  final String hostName;

  /// macos, linux or windows.
  final String platform;

  /// Which Grid it is running.
  final String appVersion;

  /// The grids it is signed in to.
  final List<GridRow> grids;
}

/// It did not work, and the message says what to do about it.
final class PhoneLinkFailed extends PhoneLinkState {
  const PhoneLinkFailed(this.message, {required this.stillPaired});

  /// Shown to the person as-is.
  final String message;

  /// Whether Reconnect is worth offering, or whether this needs a new code.
  final bool stillPaired;
}

/// Drives the link.
final phoneLinkProvider = NotifierProvider<PhoneLinkController, PhoneLinkState>(
  PhoneLinkController.new,
);

/// Pairs, connects, and keeps what the computer said.
class PhoneLinkController extends Notifier<PhoneLinkState> {
  final _store = const PairedHostStore();
  RelayPhoneClient? _client;

  @override
  PhoneLinkState build() {
    ref.onDispose(() => _client?.close());
    return const PhoneLinkUnpaired();
  }

  /// Reconnects to the stored computer, if there is one.
  Future<void> restore() async {
    final offer = await _store.read();
    if (offer == null) {
      state = const PhoneLinkUnpaired();
      return;
    }
    await _connect(offer);
  }

  /// Pairs with the computer [code] came from.
  Future<void> pair(String code) async {
    final offer = PairingOffer.parse(code);
    if (offer == null) {
      state = const PhoneLinkFailed(
        "That doesn't look like a Grid pairing code. Copy the whole line from "
        'Grid on your computer.',
        stillPaired: false,
      );
      return;
    }
    await _connect(offer);
  }

  /// Tries the stored computer again.
  Future<void> reconnect() => restore();

  /// Asks the computer again, over the connection that is already open.
  ///
  /// Distinct from [reconnect] on purpose: re-dialling would spend a pairing
  /// code to answer a question this phone can already ask.
  Future<void> refresh() async {
    final client = _client;
    final current = state;
    if (client == null || !client.isOpen || current is! PhoneLinkConnected) {
      return reconnect();
    }
    try {
      final status = await client.call('status.get');
      final grids = await client.call('grids.list');
      state = PhoneLinkConnected(
        hostName: client.hostName,
        platform: '${status['platform'] ?? 'unknown'}',
        appVersion: '${status['appVersion'] ?? '?'}',
        grids: _readGrids(grids),
      );
    } on RelayPhoneFailure catch (failure) {
      state = PhoneLinkFailed(
        failure.message,
        // A spent code leaves this phone paired on paper and useless in fact,
        // so send it to the screen that can fix that rather than to Try again.
        stillPaired: !failure.needsNewCode && await _isPaired(),
      );
    }
  }

  /// Asks the computer something over the open channel.
  ///
  /// The client is private on purpose — one connection, owned here — so
  /// everything else that needs the computer goes through this. Throws
  /// [RelayPhoneFailure] when there is no link, which is the same thing every
  /// caller already has to handle.
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final client = _client;
    if (client == null || !client.isOpen) {
      throw const RelayPhoneFailure('Not connected to your computer.');
    }
    return client.call(method, params);
  }

  /// Forgets the computer.
  Future<void> unpair() async {
    await _client?.close();
    _client = null;
    await _store.clear();
    state = const PhoneLinkUnpaired();
  }

  Future<void> _connect(PairingOffer offer) async {
    await _client?.close();
    state = const PhoneLinkConnecting('Connecting');
    try {
      final client = await RelayPhoneClient.connect(
        offer,
        onLog: (step) {
          // Only while still connecting: a log line arriving after the link is
          // up must not knock the screen back to a spinner.
          if (state is PhoneLinkConnecting) state = PhoneLinkConnecting(step);
        },
      );
      _client = client;

      // First, before anything else this connection is for. An invite opens
      // one connection and is then spent, so by now the code that got us here
      // is already dead — and a link that drops before this runs strands the
      // phone until somebody types a new code by hand. Securing the next way
      // in is worth more than the screen being a second faster.
      state = const PhoneLinkConnecting('Saving this computer');
      await _storeRenewedOffer(offer, client);

      state = const PhoneLinkConnecting('Reading your computer');
      final status = await client.call('status.get');
      final grids = await client.call('grids.list');

      state = PhoneLinkConnected(
        hostName: client.hostName,
        platform: '${status['platform'] ?? 'unknown'}',
        appVersion: '${status['appVersion'] ?? '?'}',
        grids: _readGrids(grids),
      );
    } on RelayPhoneFailure catch (failure) {
      state = PhoneLinkFailed(failure.message, stillPaired: await _isPaired());
    } on Object {
      state = PhoneLinkFailed(
        'Something went wrong connecting to your computer.',
        stillPaired: await _isPaired(),
      );
    }
  }

  Future<void> _storeRenewedOffer(
    PairingOffer offer,
    RelayPhoneClient client,
  ) async {
    try {
      final renewed = await client.call('pairing.renew');
      final relay = PairingRelayEndpoint.fromJson(renewed['relay']);
      if (relay == null) return;
      await _store.write(
        PairingOffer(
          deviceToken: offer.deviceToken,
          hostPublicKey: offer.hostPublicKey,
          hostName: client.hostName,
          relay: relay,
        ),
      );
    } on RelayPhoneFailure {
      // An older computer has no `pairing.renew`. The link still works; this
      // phone will just need a fresh code next time, so say nothing here and
      // let the reconnect failure explain itself when it happens.
    }
  }

  Future<bool> _isPaired() async => await _store.read() != null;

  List<GridRow> _readGrids(Map<String, Object?> result) {
    final rows = result['grids'];
    if (rows is! List) return const [];
    return [
      for (final row in rows)
        if (row is Map)
          (
            id: '${row['id'] ?? ''}',
            name: '${row['name'] ?? ''}',
            type: '${row['type'] ?? ''}',
            email: '${row['email'] ?? ''}',
          ),
    ];
  }
}
