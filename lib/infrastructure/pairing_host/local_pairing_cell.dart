/// The pairing cell, served by this computer instead of by somebody's server.
///
/// A relay exists to join two machines that can each only dial *out*. Put a
/// tunnel in front of this computer and that stops being true of one of them:
/// the phone dials, and the thing it reaches is the desktop itself. Most of a
/// relay then has nothing left to do — no control channel telling a desktop a
/// phone arrived, no splice joining two sockets, no proof of a host id claimed
/// by a stranger. See ADR 0045 D-a.
///
/// What is kept is the one route a phone actually dials, frame for frame, so
/// **the phone cannot tell the difference and does not change**:
///
/// ```
/// phone ──wss──▶ /v1/connect/<relayHostId>
///         {"type":"relay-auth","mode":"connect","credential":"…"}
///         ◀── refused: {"type":"relay-hello","ok":false,"code":…} then close
///         ── accepted: every frame after this is the sealed channel
/// ```
///
/// `pairing_relay/` in the CLI repo stays the reference implementation, and
/// stays what the cross-repo probe runs against.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:grid_pairing/grid_pairing.dart';

import 'cell_credentials.dart';
import 'device_registry.dart';
import 'mobile_channel_session.dart';
import 'mobile_rpc_service.dart';

/// How long a phone has to say who it is before the socket is dropped.
///
/// A socket that opened and then said nothing is either a scan or a stall, and
/// either way it is holding a connection this computer is serving for free.
const Duration kConnectAuthDeadline = Duration(seconds: 10);

/// The close codes the cell answers with, matching `pairing_relay`'s so a
/// phone's existing handling of them is unchanged.
const int kCellBadCredential = 4401;
const int kCellUnknownHost = 4404;

/// Serves phones on loopback, for a tunnel to put in front of.
class LocalPairingCell {
  LocalPairingCell({
    required E2eeKeyPair keyPair,
    required DeviceRegistry registry,
    required MobileRpcService rpc,
    required void Function(String message) onEvent,
    Random? random,
  }) : _keyPair = keyPair,
       _registry = registry,
       _rpc = rpc,
       _onEvent = onEvent,
       _random = random ?? Random.secure(),
       relayHostId = deriveRelayHostId(keyPair.publicKey);

  /// The id this computer's key owns, and the path a phone dials.
  final String relayHostId;

  final E2eeKeyPair _keyPair;
  final DeviceRegistry _registry;
  final MobileRpcService _rpc;
  final void Function(String message) _onEvent;
  final Random _random;
  final _credentials = CellCredentials();

  HttpServer? _server;

  /// Where a phone reaches this cell from outside, once something has put it
  /// there.
  ///
  /// Null until a tunnel is open. A pairing code minted before that would carry
  /// a loopback address, which on a phone means the phone — so minting refuses
  /// rather than producing a code that cannot work.
  String? publicOrigin;

  /// The loopback port this is listening on, for a tunnel to point at.
  int get port => _server?.port ?? 0;

  /// Start listening. Loopback only: the tunnel is the only way in from
  /// outside, so nothing here is reachable on the network by accident.
  Future<void> start({int port = 0}) async {
    if (_server != null) return;
    final server = _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    server.listen(
      _onRequest,
      onError: (Object error) {
        _onEvent('the cell stopped accepting: $error');
      },
    );
    _onEvent('serving phones on 127.0.0.1:${server.port}');
  }

  /// Stop listening. Phones already connected are dropped with it.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  /// A fresh pairing code's half of the endpoint, tied to [relayDeviceId].
  ///
  /// Throws when there is no public address yet: a code is useless without one
  /// and a code that looks fine and cannot work is worse than a refusal.
  PairingRelayEndpoint mintInvite(String relayDeviceId) =>
      _mint(relayDeviceId, life: kInviteLife, singleUse: true);

  /// A way back in for a phone that has already proved itself, handed over only
  /// inside the sealed channel.
  PairingRelayEndpoint mintResume(String relayDeviceId) =>
      _mint(relayDeviceId, life: kResumeLife, singleUse: false);

  /// Forget every credential [deviceId] could still connect with.
  void revoke(String deviceId) => _credentials.revokeFor(deviceId);

  PairingRelayEndpoint _mint(
    String relayDeviceId, {
    required Duration life,
    required bool singleUse,
  }) {
    final origin = publicOrigin;
    if (origin == null) {
      throw StateError('there is no public address for a phone to dial yet');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _credentials.sweep(nowMs: now);
    final token = _token();
    _credentials.mint(
      token,
      deviceId: relayDeviceId,
      life: life,
      singleUse: singleUse,
      nowMs: now,
    );
    return PairingRelayEndpoint(
      cellUrl: origin,
      relayHostId: relayHostId,
      inviteToken: token,
      inviteExpiresAtMs: now + life.inMilliseconds,
    );
  }

  String _token() => base64Url
      .encode(List.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  Future<void> _onRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/healthz') return _healthz(request);
    final dialled = _connectPath(path);
    if (dialled == null) return _plain(request, HttpStatus.notFound, 'no');
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      return _plain(request, HttpStatus.badRequest, 'websocket only');
    }
    final socket = await WebSocketTransformer.upgrade(request);
    await _serve(socket, dialled);
  }

  /// The `relayHostId` a request dialled, or null when it isn't a connect.
  static String? _connectPath(String path) =>
      _connect.firstMatch(path)?.group(1);

  Future<void> _healthz(HttpRequest request) {
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true, 'origin': publicOrigin}));
    return request.response.close();
  }

  Future<void> _plain(HttpRequest request, int status, String body) {
    request.response
      ..statusCode = status
      ..write(body);
    return request.response.close();
  }

  /// One phone, from its first frame to whichever of us closes the socket.
  Future<void> _serve(WebSocket socket, String dialled) async {
    // Everything after the opening frame belongs to the session, and may well
    // arrive before the session is listening — so it is buffered here rather
    // than dropped. A controller queues; a broadcast stream would not.
    final rest = StreamController<dynamic>();
    var opened = false;
    final auth = Completer<Object?>();
    socket.listen(
      (data) {
        if (opened) {
          rest.add(data);
          return;
        }
        opened = true;
        if (!auth.isCompleted) auth.complete(data);
      },
      onError: rest.addError,
      onDone: rest.close,
      cancelOnError: true,
    );

    final Object? first;
    try {
      first = await auth.future.timeout(kConnectAuthDeadline);
    } on TimeoutException {
      return _refuse(socket, kCellBadCredential, 'said nothing');
    }

    final admitted = _admit(first, dialled);
    if (admitted.deviceId == null) {
      return _refuse(socket, admitted.code, admitted.because);
    }

    await MobileChannelSession(
      socket: socket,
      incoming: rest.stream,
      hostKeyPair: _keyPair,
      registry: _registry,
      rpc: _rpc,
      relayHostId: relayHostId,
      onEvent: _onEvent,
    ).serve();
  }

  /// Who the opening frame admits, or why it admits nobody.
  ///
  /// ⚠️ Every refusal below the host check answers the **same** code and the
  /// same sentence. Unreadable, wrong shape, expired, already spent, never
  /// minted — telling those apart helps nobody who should be here, and tells
  /// somebody who should not exactly which guess was close.
  _Admission _admit(Object? first, String dialled) {
    if (dialled != relayHostId) {
      return const _Admission.no(
        kCellUnknownHost,
        'it dialled a host this computer is not',
      );
    }
    const bad = _Admission.no(kCellBadCredential, 'its credential was refused');
    if (first is! String) return bad;
    final Object? value;
    try {
      value = jsonDecode(first);
    } on FormatException {
      return bad;
    }
    if (value is! Map ||
        value['type'] != 'relay-auth' ||
        value['mode'] != 'connect') {
      return bad;
    }
    final credential = value['credential'];
    if (credential is! String) return bad;
    final deviceId = _credentials.spend(
      credential,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    return deviceId == null ? bad : _Admission.yes(deviceId);
  }

  /// Say why, then close. The phone shows a sentence rather than "connection
  /// closed", which is the only reason this frame exists.
  Future<void> _refuse(WebSocket socket, int code, String because) async {
    _onEvent('refused a phone: $because');
    try {
      socket.add(
        jsonEncode({'type': 'relay-hello', 'ok': false, 'code': code}),
      );
    } on Object {
      // The socket died first; there is nobody left to tell.
    }
    await socket.close(code, 'refused');
  }
}

final RegExp _connect = RegExp(r'^/v1/connect/([A-Za-z0-9_-]+)$');

/// Whether a phone gets in, and what to say when it doesn't.
class _Admission {
  const _Admission.yes(String this.deviceId) : code = 0, because = '';
  const _Admission.no(this.code, this.because) : deviceId = null;

  final String? deviceId;
  final int code;
  final String because;
}
