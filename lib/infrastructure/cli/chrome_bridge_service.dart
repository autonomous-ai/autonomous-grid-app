import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import 'host_environment.dart';

/// The DevTools port the app's own browser listens on. Chrome's default, so a
/// browser the user already started with `--remote-debugging-port` is picked up
/// instead of a second one being launched beside it.
const int kChromeBridgePort = 9222;

/// The npm package that turns a DevTools endpoint into MCP browser tools.
const String kChromeDevtoolsMcpPackage = 'chrome-devtools-mcp@latest';

/// Where a Chromium browser might be on this platform, best first. Absolute
/// paths are checked on disk; bare names are looked up on the augmented `PATH`.
///
/// Pure, so the list is readable (and testable) without a browser installed.
List<String> chromeBinaryCandidates() {
  if (Platform.isMacOS) {
    return const [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
    ];
  }
  if (Platform.isLinux) {
    return const [
      'google-chrome',
      'chromium',
      'chromium-browser',
      'microsoft-edge',
      'brave-browser',
    ];
  }
  return const [
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  ];
}

/// The browser this app can launch, or null when there is none.
String? resolveChromeBinary() {
  for (final candidate in chromeBinaryCandidates()) {
    if (!candidate.contains(Platform.pathSeparator)) {
      final found = HostEnvironment.findExecutable(candidate);
      if (found != null) return found;
      continue;
    }
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// A browser this app starts and keeps, reachable over the DevTools protocol.
///
/// **Why the app owns the process.** A browser launched per turn is a browser
/// that dies per turn: `claude -p` is one shot, so any MCP server it spawns —
/// and the Chrome that server started — goes down with it, and the next turn
/// opens a blank browser with none of the state the last one built up. Holding
/// the process here outlives the turn, which is the whole point of the lane.
///
/// It is a **separate profile** (`~/.grid/app/chrome`), not the user's: Chrome
/// refuses a second launch against a profile already open, and pointing at
/// theirs would put an automated agent inside every session they are signed in
/// to. The trade is that this browser is signed in to nothing — the extension
/// lane is the one that has their logins.
class ChromeBridge {
  ChromeBridge({this.port = kChromeBridgePort, String? userDataDir})
    : _userDataDir = userDataDir ?? '${GridPaths.home.path}/app/chrome';

  final int port;
  final String _userDataDir;

  Process? _process;

  /// How long a freshly launched browser gets to open its DevTools port before
  /// the lane gives up and says so. Cold-starting Chrome on a busy machine is
  /// seconds, not milliseconds.
  static const _startTimeout = Duration(seconds: 15);
  static const _pollInterval = Duration(milliseconds: 250);
  static const _probeTimeout = Duration(seconds: 1);

  /// The DevTools endpoint, or null when no browser could be brought up.
  ///
  /// Null is a real answer, not an error: the caller drops the browser lane and
  /// records why, rather than launching a turn whose tools point at nothing.
  Future<String?> ensureRunning() async {
    if (await _alive()) return url;
    final binary = resolveChromeBinary();
    if (binary == null) return null;
    try {
      _process = await Process.start(
        binary,
        [
          '--remote-debugging-port=$port',
          '--user-data-dir=$_userDataDir',
          '--no-first-run',
          '--no-default-browser-check',
        ],
        environment: {...Platform.environment, 'PATH': HostEnvironment.path()},
      );
    } on ProcessException {
      return null;
    }
    return await _waitForPort() ? url : null;
  }

  String get url => 'http://127.0.0.1:$port';

  /// Stop the browser this bridge started. A browser that was already listening
  /// when [ensureRunning] was called belongs to the user and is left alone.
  void dispose() {
    _process?.kill();
    _process = null;
  }

  Future<bool> _waitForPort() async {
    final deadline = DateTime.now().add(_startTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _alive()) return true;
      await Future<void>.delayed(_pollInterval);
    }
    dispose();
    return false;
  }

  /// Whether something is already answering DevTools on [port].
  Future<bool> _alive() async {
    final client = HttpClient()..connectionTimeout = _probeTimeout;
    try {
      final request = await client
          .getUrl(Uri.parse('$url/json/version'))
          .timeout(_probeTimeout);
      final response = await request.close().timeout(_probeTimeout);
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

/// The app's browser, kept for the life of the app rather than the turn.
final chromeBridgeProvider = Provider<ChromeBridge>((ref) {
  final bridge = ChromeBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});

/// `npx`, which runs the browser MCP server, or null when Node isn't installed.
final npxPathProvider = Provider<String?>(
  (ref) => HostEnvironment.findExecutable('npx'),
);

/// Whether the fallback lane has both halves it needs: a browser to drive and
/// the runner for the MCP server that drives it. Checked before a turn commits
/// to the lane, so a machine without Node degrades to "no browser" with a
/// reason instead of a turn whose tools never load.
final chromeBridgeAvailableProvider = Provider<bool>(
  (ref) => ref.watch(npxPathProvider) != null && resolveChromeBinary() != null,
);
