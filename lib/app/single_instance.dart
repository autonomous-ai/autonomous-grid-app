import 'dart:io';

/// Port used purely as a cross-process mutex. Pick a fixed value in the private
/// range that no real service is expected to occupy.
const int _kSingleInstancePort = 52677;

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
/// holds it for its whole lifetime; later instances fail to bind and should
/// exit immediately. Returns `true` if this process is the sole instance.
Future<bool> acquireSingleInstanceLock() async {
  if (_instanceLock != null) return true;
  try {
    _instanceLock = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      _kSingleInstancePort,
    );
    return true;
  } on SocketException {
    return false;
  }
}
