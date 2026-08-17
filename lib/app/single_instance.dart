import 'dart:async';
import 'dart:io';

/// Port used purely as a cross-process mutex. Pick a fixed value in the private
/// range that no real service is expected to occupy.
const int _kSingleInstancePort = 52677;

/// One-byte reply the live instance sends on every accepted connection. A new
/// launch that fails to bind uses this to tell a *live* Grid apart from a stale
/// holder of the port (a wedged or orphaned process that no longer serves).
const int _kAliveByte = 0x47; // 'G'

/// How long a launch keeps trying for the port before it accepts that another
/// Grid owns the window.
///
/// Sized for the Sparkle relaunch, not for a user double-clicking the app: the
/// updater starts the new copy while the old one is still quitting, and quitting
/// stops the serving engines first (`WindowLifecycleScope.didRequestAppExit`,
/// up to 8s). The old process holds this port until it actually exits, so a
/// launch that gave up on the first refusal would exit into nothing and the
/// update would look like the app refusing to reopen.
const Duration _kHandoverWindow = Duration(seconds: 10);

/// Gap between attempts inside [_kHandoverWindow].
const Duration _kRetryGap = Duration(milliseconds: 300);

/// How long the holder gets to answer a liveness probe.
///
/// Deliberately generous. This is the *other* half of the same race: a Mac
/// mid-shutdown — stopping engines, writing state, with a slower CPU and disk
/// than the machine this was written on — can easily take longer than a snappy
/// timeout to answer, and reading that silence as "the holder is dead" makes
/// this launch seize the port and open a second window beside the first. Two
/// live windows then both call `show()` + `focus()` and fight, which is the
/// "reopens forever" flicker this file exists to prevent.
const Duration _kProbeTimeout = Duration(seconds: 3);

/// Beat allowed for a port with nothing behind it to come free before this
/// launch takes the window anyway.
const Duration _kSettleGap = Duration(milliseconds: 400);

/// Held for the lifetime of the winning instance so the bound port is never
/// released early (and never garbage-collected).
ServerSocket? _instanceLock;

/// How a launch resolved its claim on the single-instance mutex.
///
/// Three outcomes rather than a bool, because they are not equally benign and
/// the log has to be able to say which one happened: [reclaimed] means this
/// process decided another one was dead, and if that call was wrong the user
/// gets two Grid windows.
enum InstanceLock {
  /// The port was free — this is the only Grid running.
  acquired,

  /// The port was held by something that never answered, so this launch took it
  /// over. Expected after a crash or a force-quit; suspicious otherwise.
  reclaimed,

  /// A live Grid answered and kept the window. This launch must exit.
  deferred,
}

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
/// byte; later instances fail to bind and exit.
///
/// Two things make that harder than one bind call, and both of them are the
/// Sparkle auto-update, which quits the running app and relaunches the new copy
/// back-to-back:
///
/// * The old instance is **still alive** for as long as its quit takes, so the
///   relaunched copy meets a holder that is on its way out. It waits
///   [_kHandoverWindow] for the port to come free instead of exiting on the
///   first refusal.
/// * The old instance may be **too busy to answer** while it shuts its engines
///   down. A tight probe timeout reads that as death, and the relaunched copy
///   opens a second window next to the first — see [_kProbeTimeout].
///
/// A failed bind is still not proof that a healthy Grid is running: an orphaned
/// or wedged process can hold the port while serving nothing. If nothing
/// answers at all we assume the holder is dead and reclaim the port rather than
/// locking the user out of their own app for good.
Future<InstanceLock> acquireSingleInstanceLock() async {
  if (_instanceLock != null) return InstanceLock.acquired;

  final deadline = DateTime.now().add(_kHandoverWindow);
  while (true) {
    final server = await _tryBind();
    if (server != null) {
      _serve(server);
      return InstanceLock.acquired;
    }

    // The port is held. Only a real, responding Grid keeps us out.
    if (!await _liveInstanceResponds()) return _reclaim();

    if (!DateTime.now().isBefore(deadline)) return InstanceLock.deferred;
    await Future<void>.delayed(_kRetryGap);
  }
}

/// Takes the port back from a holder that stopped answering.
///
/// One more attempt after a beat, in case the holder was mid-exit and simply
/// hadn't released the socket yet. If it still won't bind, the port is wedged by
/// something we can't reclaim cleanly — proceed as the live instance anyway
/// rather than force-closing the user out of their own app.
Future<InstanceLock> _reclaim() async {
  await Future<void>.delayed(_kSettleGap);
  final server = await _tryBind();
  if (server != null) _serve(server);
  return InstanceLock.reclaimed;
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
/// the expected [_kAliveByte] within [_kProbeTimeout]. Any failure — refused,
/// silent, wrong reply, timeout — is treated as "no live instance".
///
/// A port with nothing listening refuses the connection immediately, so the
/// generous timeout costs a wedged-port launch nothing: it is only ever spent
/// on a process that accepted the connection and is slow to reply.
Future<bool> _liveInstanceResponds() async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _kSingleInstancePort,
      timeout: _kProbeTimeout,
    );
    final first = await socket.first.timeout(_kProbeTimeout);
    return first.isNotEmpty && first.first == _kAliveByte;
  } on Object {
    return false;
  } finally {
    socket?.destroy();
  }
}
