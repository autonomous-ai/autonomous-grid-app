import 'dart:io';

/// Finds a free loopback TCP port so a caller can hand it to a child process
/// instead of trusting a fixed default. A typedef (not a bare function) so it
/// can be injected via a provider and pinned in tests without binding a real
/// socket.
typedef FreePortFinder = Future<int> Function();

/// Asks the OS for a currently-unused loopback port by binding to port 0 — the
/// kernel hands back a free ephemeral port — then releasing it and returning the
/// number.
///
/// Why: the built-in engine's local server defaults to 8081, a common port that
/// another app on the user's machine may already hold ("Port 8081 already in
/// use; aborting"). Handing `grid join` a freshly-picked port instead avoids
/// that collision.
///
/// A tiny race exists between releasing the socket here and the engine binding
/// it; if the engine loses that race the CLI still reports "port in use", which
/// the controller surfaces as a start failure.
Future<int> findFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
