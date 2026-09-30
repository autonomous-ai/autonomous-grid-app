/// The one piece of state this app has: which computer it is talking to, and
/// how that is going. The states themselves are in `phone_link_state.dart`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_pairing/grid_pairing.dart';
import 'package:grid_pairing/locator_http_io.dart';

import 'pair_token_store.dart';
import 'phone_link_state.dart';
import 'relay_phone_client.dart';

export 'phone_link_state.dart';

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

/// Drives the link.
final phoneLinkProvider = NotifierProvider<PhoneLinkController, PhoneLinkState>(
  PhoneLinkController.new,
);

/// Which connection the lists are reading through — changes on every dial.
///
/// Watched by every provider that asks the computer something, so an answer
/// that failed while the link was down is asked again the moment it is back.
/// Riverpod compares the int, so a refresh on the same connection — or the
/// dropped-and-redialling state in between — asks nothing again.
final phoneLinkSessionProvider = Provider<int?>(
  (ref) => shownLink(ref.watch(phoneLinkProvider))?.session,
);

/// Asks the computer [method] from inside a provider, and asks again whenever
/// the link is re-dialled.
///
/// The one way a provider reads the computer: a provider that called the
/// controller directly would keep the error it got while the link was down
/// until somebody pulled to refresh, even though the link came back by itself.
Future<Map<String, Object?>> askComputer(
  Ref ref,
  String method, [
  Map<String, Object?> params = const {},
]) {
  ref.watch(phoneLinkSessionProvider);
  return ref.read(phoneLinkProvider.notifier).call(method, params);
}

/// How long to wait before each quiet attempt to put a dropped link back.
///
/// The first is immediate: most drops are the phone having been locked, and the
/// computer is right there. The rest space out so a computer that really has
/// gone to sleep is not dialled every second for as long as the app is open.
const List<Duration> _kRedialAfter = [
  Duration.zero,
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
];

/// How long a socket that survived the phone being put down has to answer.
///
/// Short, because the person is looking at the screen: iOS often leaves a
/// socket that *looks* open after a lock and will never carry another frame,
/// and the default twenty seconds would be twenty seconds of a frozen chat.
const Duration _kProbeWithin = Duration(seconds: 4);

/// Pairs, connects, keeps what the computer said — and puts the link back when
/// it drops.
class PhoneLinkController extends Notifier<PhoneLinkState> {
  final _store = const PairTokenStore();
  RelayPhoneClient? _client;
  int _session = 0;

  /// Whether the app is in the background, where iOS will not let a socket
  /// live — so a drop there waits for [resumed] rather than dialling into it.
  bool _away = false;

  /// The re-dial in progress, shared by everyone who noticed the link was gone.
  ///
  /// The chat list, the projects and the open transcript all ask the computer
  /// at the same moment, so three of them find a dead socket at once. Without
  /// this they would dial three times over, each racing the others for the
  /// link they are trying to restore.
  Future<void>? _redial;

  @override
  PhoneLinkState build() {
    ref.onDispose(() => _client?.close());
    return const PhoneLinkUnpaired();
  }

  /// Reconnects to the stored computer, if there is one, with the full-screen
  /// progress — what opening the app looks like.
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

  /// Tries the stored computer again — quietly, behind the screen already
  /// showing, when there is one.
  Future<void> reconnect() => _rejoin();

  /// The app went to the background.
  void paused() => _away = true;

  /// The app is back in front of somebody.
  ///
  /// The moment a link is most likely to be dead without anyone having said
  /// so: iOS ends sockets behind a locked screen, and sometimes leaves one that
  /// still reports open. So the link is checked here — cheaply, with a short
  /// deadline — rather than on the first tap, which would be a frozen chat.
  Future<void> resumed() async {
    _away = false;
    final current = state;
    switch (current) {
      case PhoneLinkConnected():
        if (await _answers()) return;
        await _client?.close();
        return _rejoin();
      case PhoneLinkInterrupted():
        return _rejoin();
      case PhoneLinkFailed(stillPaired: true):
        return restore();
      case PhoneLinkUnpaired() || PhoneLinkConnecting() || PhoneLinkFailed():
        return;
    }
  }

  /// Asks the computer again, over the connection that is already open.
  ///
  /// Distinct from [reconnect] on purpose: re-dialling means a locator read and
  /// a fresh handshake to answer a question this phone can already ask.
  Future<void> refresh() async {
    final client = _client;
    final current = state;
    if (client == null || !client.isOpen || current is! PhoneLinkConnected) {
      return _rejoin();
    }
    try {
      final status = await client.call('status.get');
      final grids = await client.call('grids.list');
      state = current.refreshed(
        platform: '${status['platform'] ?? 'unknown'}',
        appVersion: '${status['appVersion'] ?? '?'}',
        grids: readGridRows(grids),
      );
    } on RelayPhoneFailure catch (failure) {
      if (failure.needsNewCode) return _spent(failure);
      await client.close();
      await _rejoin();
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

  /// Forgets the computer.
  Future<void> unpair() async {
    await _client?.close();
    _client = null;
    await _store.clear();
    state = const PhoneLinkUnpaired();
  }

  /// The open connection, re-dialling if the last one went away.
  ///
  /// A phone is put down for an hour and the computer sleeps or moves to another
  /// address; either way the next thing the person taps must not simply fail.
  Future<RelayPhoneClient> _liveClient() async {
    final open = _client;
    if (open != null && open.isOpen) return open;
    await _rejoin();
    final client = _client;
    if (client == null || !client.isOpen) {
      throw const RelayPhoneFailure('Not connected to your computer.');
    }
    return client;
  }

  /// Puts the link back, once, however many callers noticed it was gone.
  Future<void> _rejoin() =>
      _redial ??= _redialQuietly().whenComplete(() => _redial = null);

  /// Dials again behind the screen that is showing, a few times over.
  ///
  /// Falls back to [restore] — the full-screen path — only when there is no
  /// screen yet to keep.
  Future<void> _redialQuietly() async {
    final last = shownLink(state);
    final paired = await _store.read();
    if (last == null || paired == null) return restore();
    RelayPhoneFailure? failure;
    for (final wait in _kRedialAfter) {
      // Behind a locked screen a dial cannot hold; [resumed] starts over.
      if (_away) return;
      await Future<void>.delayed(wait);
      state = PhoneLinkInterrupted(last);
      failure = await _dial(paired.token);
      if (failure == null) return;
      if (failure.needsNewCode) return _spent(failure);
    }
    state = PhoneLinkInterrupted(last, problem: failure?.message);
  }

  /// First connection: the progress fills the screen, because there is
  /// nothing else yet to show.
  Future<void> _connect(PairToken token, {String hostName = ''}) async {
    state = PhoneLinkConnecting(
      hostName.isEmpty ? 'Connecting' : 'Connecting to $hostName',
    );
    final failure = await _dial(
      token,
      onStep: (step) {
        // Only while still connecting: a log line arriving after the link is
        // up must not knock the screen back to a spinner.
        if (state is PhoneLinkConnecting) state = PhoneLinkConnecting(step);
      },
    );
    if (failure == null) return;
    if (failure.needsNewCode) return _spent(failure);
    state = PhoneLinkFailed(failure.message, stillPaired: await _isPaired());
  }

  /// Opens a fresh connection and reads the computer, returning why not.
  ///
  /// Leaves the state at [PhoneLinkConnected] on success and untouched on
  /// failure, so each caller decides what a failure looks like from where it
  /// stands — a full-screen error on first open, a banner over a live app.
  Future<RelayPhoneFailure?> _dial(
    PairToken token, {
    void Function(String step)? onStep,
  }) async {
    await _client?.close();
    _client = null;
    try {
      final client = await RelayPhoneClient.connect(
        token,
        locator: ref.read(locatorClientProvider),
        onLost: (_) => _linkLost(),
        onLog: onStep,
      );
      _client = client;

      // Remembered before anything else can go wrong, and with the name this
      // computer just gave: the code does not expire, so a phone that fails at
      // the next step still knows which computer it belongs to instead of
      // coming back to a blank "type a code" screen as though it never paired.
      await _store.write(token: token, hostName: client.hostName);

      onStep?.call('Reading your computer');
      final status = await client.call('status.get');
      final grids = await client.call('grids.list');
      state = PhoneLinkConnected(
        hostName: client.hostName,
        platform: '${status['platform'] ?? 'unknown'}',
        appVersion: '${status['appVersion'] ?? '?'}',
        grids: readGridRows(grids),
        session: ++_session,
      );
      return null;
    } on RelayPhoneFailure catch (failure) {
      return failure;
    } on Object {
      return const RelayPhoneFailure(
        'Something went wrong connecting to your computer.',
      );
    }
  }

  /// Whether the open socket still carries an answer, asked briefly.
  Future<bool> _answers() async {
    final client = _client;
    if (client == null || !client.isOpen) return false;
    try {
      await client.call('status.get', const {}, _kProbeWithin);
      return true;
    } on Object {
      return false;
    }
  }

  /// The channel went away by itself.
  ///
  /// The screen stays, with a banner saying the link is coming back, and the
  /// dial starts at once — unless the app is in the background, where it would
  /// only fail, and [resumed] will start it instead.
  void _linkLost() {
    final current = state;
    if (current is! PhoneLinkConnected) return;
    state = PhoneLinkInterrupted(current);
    if (!_away) unawaited(_rejoin());
  }

  /// The code no longer opens the computer's record — back to typing one.
  void _spent(RelayPhoneFailure failure) =>
      state = PhoneLinkFailed(failure.message, stillPaired: false);

  Future<bool> _isPaired() async => await _store.read() != null;
}

/// The grids in a `grids.list` answer.
List<GridRow> readGridRows(Map<String, Object?> result) {
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
