import 'dart:async';
import 'dart:io';

/// Port used purely as a cross-process mutex. Pick a fixed value in the private
/// range that no real service is expected to occupy.
const int _kSingleInstancePort = 52677;

/// One-byte reply the live instance sends on every accepted connection. A new
/// launch that fails to bind uses this to tell a *live* Grid apart from a stale
/// holder of the port (a wedged or orphaned process that no longer serves).
const int _kAliveByte = 0x47; // 'G'

/// Held for the lifetime of the winning instance so the bound port is never
/// released early (and never garbage-collected).
ServerSocket? _instanceLock;

/// Ensures only one Grid window exists at a time.
///
/// `flutter run` on macOS launches the app by exec'ing the binary directly and
/// then calls `open` to foreground it. macOS doesn't recognise the exec'd
/// process as the running instance of the bundle, so `open` spawns a *second*
/// instance — and on macOS 26 the duplicates each call `windowManager.show()`
/// + `focus()`, fighting for focus and looking like the app "reopens forever".
///
/// We bind a fixed loopback port as a mutex: the first instance acquires it and
/// holds it for its whole lifetime, answering each connection with a liveness
/// byte; later instances fail to bind and exit. Returns `true` if this process
/// is (or becomes) the sole live instance.
///
/// Crucially, a failed bind is *not* taken as proof that a healthy Grid is
/// running. An orphaned or wedged process — a detached `flutter run` child, a
/// half-crashed instance, a port left in a bad state — can hold the port while
/// serving nothing. If that happened, every future launch used to `exit(0)`
/// forever and looked exactly like the app force-closing on start. So on a bind
/// failure we *probe* the holder: only a real, responding Grid keeps us out.
/// If nothing answers, we assume the holder is dead and reclaim the port.
Future<bool> acquireSingleInstanceLock() async {
  if (_instanceLock != null) return true;

  final server = await _tryBind();
  if (server != null) {
    _serve(server);
    return true;
  }

  // Bind failed: the port is held. Confirm a live Grid is really behind it
  // before deferring — otherwise a stale holder would lock us out for good.
  if (await _liveInstanceResponds()) return false;

  // The holder isn't answering. Give it a beat to release the port (e.g. it is
  // shutting down), then retry the bind. If it still won't bind, the port is
  // wedged by something we can't reclaim cleanly — proceed as the live instance
  // anyway rather than force-closing the user out of their own app.
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final retry = await _tryBind();
  if (retry != null) {
    _serve(retry);
    return true;
  }
  return true;
}

/// Binds the mutex port, or returns null if it's already held.
Future<ServerSocket?> _tryBind() async {
  try {
    return await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      _kSingleInstancePort,
    );
  } on SocketException {
    return null;
  }
}

/// Answers every incoming connection with [_kAliveByte] so other launches can
/// confirm this instance is alive. Held open for the process lifetime.
void _serve(ServerSocket server) {
  _instanceLock = server;
  server.listen((socket) {
    socket.add(const [_kAliveByte]);
    socket.flush().then((_) => socket.destroy()).catchError((_) {
      socket.destroy();
    });
  }, onError: (_) {});
}

/// Connects to the mutex port and returns true only if a live Grid answers with
/// the expected [_kAliveByte] within a short timeout. Any failure — refused,
/// silent, wrong reply, timeout — is treated as "no live instance".
Future<bool> _liveInstanceResponds() async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _kSingleInstancePort,
      timeout: const Duration(milliseconds: 500),
    );
    final first = await socket.first.timeout(const Duration(milliseconds: 500));
    return first.isNotEmpty && first.first == _kAliveByte;
  } on Object {
    return false;
  } finally {
    socket?.destroy();
  }
}
