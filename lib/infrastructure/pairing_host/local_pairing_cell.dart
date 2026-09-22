/// The server a phone dials, served by this computer itself.
///
/// A phone and a computer cannot dial each other, which used to mean a third
/// machine in the middle holding both ends. Put a tunnel in front of this
/// computer and that stops being true: the phone dials, and what answers is the
/// desktop. Everything the relay existed to do then has nothing left to do —
/// no control channel telling a desktop that a phone arrived, no splice joining
/// two sockets, no proof of a host id claimed by a stranger, because the key is
/// right here.
///
/// ```
/// phone ──wss──▶ /v1/connect/<relayHostId>
///         {"type":"relay-auth","mode":"connect"}
///         ◀── refused: {"type":"relay-hello","ok":false,"code":…} then close
///         ◀── admitted: {"type":"relay-hello","ok":true}
///         then the sealed channel, and nothing here reads another frame
/// ```
///
/// **Admission proves nothing and is not meant to.** The opening frame carries
/// no secret, deliberately: whoever terminates TLS sees it, and a credential
/// there would be handed to the tunnel on every reconnect. Who a phone is gets
/// settled one layer up, inside the sealed channel, where its token is
/// unreadable to anything in between (`MobileChannelSession`). All this layer
/// does is refuse a phone that dialled the wrong computer, and keep a stranger
/// who found the address from holding sockets open for free.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grid_pairing/grid_pairing.dart';

import 'device_registry.dart';
import 'mobile_channel_session.dart';
import 'mobile_rpc_service.dart';

/// How long a phone has to say who it is before the socket is dropped.
///
/// A socket that opened and then said nothing is either a scan or a stall, and
/// either way it is holding a connection this computer is serving for free.
const Duration kConnectAuthDeadline = Duration(seconds: 10);

/// How many phones may be connected, or trying to be, at once.
///
/// The address is on the public internet, so this is not about how many phones
/// a person owns — it is the ceiling on what somebody who found the address can
/// tie up. A phone uses one socket; a dozen is far more than anyone needs and
/// far less than a machine notices.
const int kMaxPhoneSockets = 12;

/// The close codes the cell answers with. A phone reads them to say something
/// useful instead of "connection closed".
const int kCellBusy = 4400;
const int kCellUnknownHost = 4404;

/// Serves phones on loopback, for a tunnel to put in front of.
class LocalPairingCell {
  LocalPairingCell({
    required E2eeKeyPair keyPair,
    required DeviceRegistry registry,
    required MobileRpcService rpc,
    required void Function(String message) onEvent,
    this.authDeadline = kConnectAuthDeadline,
  }) : _keyPair = keyPair,
       _registry = registry,
       _rpc = rpc,
       _onEvent = onEvent,
       relayHostId = deriveRelayHostId(keyPair.publicKey);

  /// The id this computer's key owns, and the path a phone dials.
  final String relayHostId;

  /// How long a socket may stay silent. A parameter so the test can prove the
  /// deadline exists without waiting out the real one.
  final Duration authDeadline;

  final E2eeKeyPair _keyPair;
  final DeviceRegistry _registry;
  final MobileRpcService _rpc;
  final void Function(String message) _onEvent;

  HttpServer? _server;
  var _open = 0;

  /// The loopback port this is listening on, for a tunnel to point at.
  int get port => _server?.port ?? 0;

  /// Whether this is serving.
  bool get isListening => _server != null;

  /// Start listening.
  ///
  /// Loopback only, and that is not a detail: the tunnel is the only way in
  /// from outside, so nothing here is reachable from the coffee shop's network
  /// because somebody opened Grid on it.
  Future<void> start({int port = 0}) async {
    if (_server != null) return;
    final server = _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    server.listen(
      _onRequest,
      onError: (Object error) => _onEvent('the cell stopped accepting: $error'),
    );
    _onEvent('serving phones on 127.0.0.1:${server.port}');
  }

  /// Stop listening. Phones already connected are dropped with it.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _onRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/healthz') return _healthz(request);
    final dialled = _connect.firstMatch(path)?.group(1);
    if (dialled == null) return _plain(request, HttpStatus.notFound, 'no');
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      return _plain(request, HttpStatus.badRequest, 'websocket only');
    }
    final socket = await WebSocketTransformer.upgrade(request);
    if (_open >= kMaxPhoneSockets) {
      return _refuse(socket, kCellBusy, 'this computer is already full');
    }
    _open++;
    try {
      await _serve(socket, dialled);
    } finally {
      _open--;
    }
  }

  /// Proof of life for whoever is looking at the tunnel, and nothing else.
  ///
  /// Not a status page: this answers on a public address, so it says that
  /// something is listening and refuses to say whose computer it is.
  Future<void> _healthz(HttpRequest request) {
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true}));
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
    if (dialled != relayHostId) {
      // A phone whose locator record is stale: the computer it dialled is one
      // this machine's key does not own. Said plainly, because the phone can
      // fix it by reading the locator again.
      return _refuse(
        socket,
        kCellUnknownHost,
        'it dialled a different computer',
      );
    }

    // Everything after the opening frame belongs to the session, and may well
    // arrive before the session is listening — so it is buffered here rather
    // than dropped. A controller queues; a broadcast stream would not.
    final rest = StreamController<dynamic>();
    var opened = false;
    final hello = Completer<Object?>();
    socket.listen(
      (data) {
        if (opened) {
          rest.add(data);
          return;
        }
        opened = true;
        if (!hello.isCompleted) hello.complete(data);
      },
      onError: rest.addError,
      onDone: rest.close,
      cancelOnError: true,
    );

    final Object? first;
    try {
      first = await hello.future.timeout(authDeadline);
    } on TimeoutException {
      return _refuse(socket, kCellBusy, 'it said nothing');
    }
    if (!_isConnectFrame(first)) {
      return _refuse(socket, kCellBusy, 'its opening frame was not a connect');
    }

    socket.add(jsonEncode({'type': 'relay-hello', 'ok': true}));
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

  /// Whether [first] is the frame a Grid phone opens with.
  ///
  /// Shape only — there is nothing in it to verify. It exists so that a port
  /// scanner, a browser and a stray proxy are dropped before this computer
  /// spends a key exchange on them.
  static bool _isConnectFrame(Object? first) {
    if (first is! String || first.length > 512) return false;
    final Object? value;
    try {
      value = jsonDecode(first);
    } on FormatException {
      return false;
    }
    return value is Map &&
        value['type'] == 'relay-auth' &&
        value['mode'] == 'connect';
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
