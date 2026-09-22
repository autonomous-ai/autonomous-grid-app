/// The one piece of state this app has: which computer it is talking to, and
/// how that is going.
///
/// A sealed type rather than a handful of booleans, so every screen has to say
/// what it shows in each case and "connected but also failed" cannot be built.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_pairing/grid_pairing.dart';
import 'package:grid_pairing/locator_http_io.dart';

import 'pair_token_store.dart';
import 'relay_phone_client.dart';

/// The locator this phone reads its computer's address from.
///
/// One pooled HTTP client for the life of the app: a phone reconnects whenever
/// it comes back to the foreground, and a client per connection leaks sockets on
/// iOS in exactly the way that is hard to see.
final locatorClientProvider = Provider<LocatorClient>((ref) {
  final http = LocatorHttp();
  ref.onDispose(http.close);
  return LocatorClient(send: http.send);
});

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
  final _store = const PairTokenStore();
  RelayPhoneClient? _client;

  /// The re-dial in progress, shared by everyone who noticed the link was gone.
  ///
  /// The chat list, the projects and the open transcript all ask the computer
  /// at the same moment, so three of them find a dead socket at once. Without
  /// this they would dial three times over — and each dial spends a relay
  /// session, so the second and third would be racing the first for the link
  /// they are trying to restore.
  Future<void>? _redial;

  @override
  PhoneLinkState build() {
    ref.onDispose(() => _client?.close());
    return const PhoneLinkUnpaired();
  }

  /// Reconnects to the stored computer, if there is one.
  Future<void> restore() async {
    final paired = await _store.read();
    if (paired == null) {
      state = const PhoneLinkUnpaired();
      return;
    }
    await _connect(paired.token, hostName: paired.hostName);
  }

  /// Pairs with the computer whose code is in [code].
  ///
  /// Takes the bare code or a `grid://pair` link, because a person either types
  /// the one or taps the other and cannot be expected to know which this wants.
  Future<void> pair(String code) async {
    final token = PairToken.tryParse(pairTokenTextOf(code));
    if (token == null) {
      state = const PhoneLinkFailed(
        'That is not a Grid code. It is 20 characters, in five groups of four, '
        'shown in Settings ▸ Phone on your computer.',
        stillPaired: false,
      );
      return;
    }
    await _connect(token);
  }

  /// Tries the stored computer again.
  Future<void> reconnect() => restore();

  /// Asks the computer again, over the connection that is already open.
  ///
  /// Distinct from [reconnect] on purpose: re-dialling means a locator read and
  /// a fresh handshake to answer a question this phone can already ask.
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
        // A code that no longer opens the record leaves this phone paired on
        // paper and useless in fact, so send it to the screen that can fix that
        // rather than to Try again.
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
  ]) async {
    final client = await _liveClient();
    return client.call(method, params);
  }

  /// The open connection, re-dialling once if the last one went away.
  ///
  /// A phone is put down for an hour and the computer sleeps or moves to another
  /// address; either way the next thing the person taps must not simply fail.
  /// The code does not expire and the address is looked up again on every
  /// connection, so there is always a way back in without anybody typing
  /// anything.
  Future<RelayPhoneClient> _liveClient() async {
    final open = _client;
    if (open != null && open.isOpen) return open;
    await (_redial ??= _reconnectOnce());
    final client = _client;
    if (client == null || !client.isOpen) {
      throw const RelayPhoneFailure('Not connected to your computer.');
    }
    return client;
  }

  Future<void> _reconnectOnce() async {
    try {
      await restore();
    } finally {
      _redial = null;
    }
  }

  /// Forgets the computer.
  Future<void> unpair() async {
    await _client?.close();
    _client = null;
    await _store.clear();
    state = const PhoneLinkUnpaired();
  }

  Future<void> _connect(PairToken token, {String hostName = ''}) async {
    await _client?.close();
    state = PhoneLinkConnecting(
      hostName.isEmpty ? 'Connecting' : 'Connecting to $hostName',
    );
    try {
      final client = await RelayPhoneClient.connect(
        token,
        locator: ref.read(locatorClientProvider),
        onLost: (_) => _linkLost(),
        onLog: (step) {
          // Only while still connecting: a log line arriving after the link is
          // up must not knock the screen back to a spinner.
          if (state is PhoneLinkConnecting) state = PhoneLinkConnecting(step);
        },
      );
      _client = client;

      // Remembered before anything else can go wrong, and with the name this
      // computer just gave: the code does not expire, so a phone that fails at
      // the next step still knows which computer it belongs to instead of
      // coming back to a blank "type a code" screen as though it never paired.
      await _store.write(token: token, hostName: client.hostName);

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

  /// The channel went away by itself.
  ///
  /// Says so rather than leaving "Connected" on screen over a dead socket — the
  /// screen offers Reconnect, and the next thing the person taps re-dials on
  /// its own anyway ([_liveClient]). Only from a connected state: a drop that
  /// arrives while already failed or unpaired has nothing to add.
  ///
  /// The reason the client reports is discarded on purpose: "the connection
  /// closed" and "the connection dropped" are the same event to the person
  /// holding the phone, and neither is a thing they can act on.
  void _linkLost() {
    if (state is! PhoneLinkConnected) return;
    state = const PhoneLinkFailed(
      'The link to your computer dropped.',
      stillPaired: true,
    );
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
