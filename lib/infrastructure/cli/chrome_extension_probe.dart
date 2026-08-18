import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// The Claude in Chrome extension, as the Chrome Web Store ids it. The one
/// string the whole browser lane hangs on: a turn launched with `--chrome` on a
/// computer without this extension loads the browser tools, finds nothing to
/// talk to, and spends context saying so.
const String kClaudeInChromeExtensionId = 'fcoeoabgfenejglbffodgkkbkcdhcgfn';

/// Where the user installs it. Built from the id above rather than pasted, so
/// the page the app opens and the folder it probes for can't drift apart.
const String kClaudeInChromeStoreUrl =
    'https://chromewebstore.google.com/detail/$kClaudeInChromeExtensionId';

/// The native messaging host that lets the extension reach Claude Code — named
/// by the manifest this app writes at launch (`ChromeHostInstaller`) and by the
/// one Claude Code writes on its own first `--chrome` run. The extension and
/// the CLI never speak directly: Chrome launches this host
/// (`~/.claude/chrome/chrome-native-host`) and relays between them.
const String kClaudeCodeNativeHost =
    'com.anthropic.claude_code_browser_extension';

/// How far this computer is from letting a turn drive the user's browser.
///
/// Three states rather than a bool because the middle one is the common case
/// and has a different answer: Chrome reads native messaging host manifests
/// **at startup**, so the launch that installs the manifest is never the launch
/// that can use it — the browser has to be restarted first.
enum ChromeExtensionState {
  /// No Chromium browser on this computer carries the extension.
  missing,

  /// The extension is installed, but no browser has handed the connection over
  /// yet: Chrome is closed, or has not restarted since the manifest landed.
  /// Browser calls have nothing to reach until it does.
  hostPending,

  /// A browser is connected right now, and a turn would get browser tools.
  ready,
}

/// Where the extension and Claude Code meet: the native host Chrome launches
/// listens on `<this dir>/<pid>.sock`, and `claude --chrome` connects to any
/// socket it finds in it. Read out of the 2.1.183 binary, not guessed.
///
/// The dir is shared rather than per-host, which is why a machine with the
/// Claude desktop app is already connected for Claude Code too — measured: with
/// only `Claude.app`'s host running, a `claude --chrome` turn reached
/// `claude-in-chrome: connected` and 49 tools against 27 without.
String claudeBridgeDir(String user) => '/tmp/claude-mcp-browser-bridge-$user';

/// The login name the bridge directory is named after.
///
/// Claude Code asks the OS (`os.userInfo().username`) and falls back to `USER`
/// / `USERNAME`. Dart has no `userInfo`, and a Grid launched from Finder gets a
/// trimmed environment that may carry neither (the reason `HostEnvironment`
/// exists), so the home directory's own name is the last resort — on macOS and
/// Linux alike that is the login name.
String bridgeUserName({
  required Map<String, String> environment,
  required String userHome,
}) {
  for (final key in const ['USER', 'USERNAME']) {
    final value = environment[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  final leaf = userHome.split('/').where((part) => part.isNotEmpty).lastOrNull;
  return leaf ?? 'default';
}

/// The user-data directory of every Chromium browser the integration supports,
/// most likely first. Pure, so the layout is testable without a browser.
///
/// Windows returns none on purpose: there the manifests live in the registry
/// (`HKCU\Software\<vendor>\NativeMessagingHosts\`), which this probe can't
/// read, and answering [ChromeExtensionState.missing] keeps the app off a lane
/// it cannot verify rather than guessing its way into a silent failure.
List<String> chromiumUserDataDirs(String userHome) {
  if (Platform.isMacOS) {
    const support = 'Library/Application Support';
    return [
      '$userHome/$support/Google/Chrome',
      '$userHome/$support/Microsoft Edge',
      '$userHome/$support/BraveSoftware/Brave-Browser',
      '$userHome/$support/Arc/User Data',
      '$userHome/$support/Vivaldi',
      '$userHome/$support/com.operasoftware.Opera',
    ];
  }
  if (Platform.isLinux) {
    return [
      '$userHome/.config/google-chrome',
      '$userHome/.config/microsoft-edge',
      '$userHome/.config/BraveSoftware/Brave-Browser',
      '$userHome/.config/vivaldi',
      '$userHome/.config/opera',
    ];
  }
  return const [];
}

/// Whether a turn could drive the user's own browser right now.
///
/// A file probe rather than a CLI call — `claude` has no non-interactive way to
/// report Chrome status (`/chrome` is a slash command inside a session), and
/// the app needs the answer before it builds the argv for a turn.
///
/// **The connected browser, not the installed file.** This used to answer
/// [ChromeExtensionState.ready] on the manifest existing, which is the wrong
/// question by one restart: Chrome reads that file at startup, so a machine
/// where it had just been written looked ready and gave every turn `--chrome`
/// with no browser behind it — an agent that talks about the browser and never
/// opens one. The socket in [claudeBridgeDir] is a browser that has actually
/// connected, which is the thing the turn needs.
///
/// A socket left behind by a host that was killed rather than closed would
/// still read as ready. That case ends as a turn whose `claude-in-chrome`
/// server never connects, which `ClaudeChatSender` already logs by name.
class ChromeExtensionProbe {
  ChromeExtensionProbe({String? userHome, String? bridgeDir})
    : _home = userHome ?? GridPaths.userHome,
      _bridgeDir = bridgeDir;

  final String _home;
  final String? _bridgeDir;

  /// The rendezvous directory this machine's browser would appear in.
  String get bridgeDir =>
      _bridgeDir ??
      claudeBridgeDir(
        bridgeUserName(environment: Platform.environment, userHome: _home),
      );

  ChromeExtensionState detect() {
    // Asked first, and on its own: a connected browser is proof enough on any
    // machine, including one whose extension lives somewhere this doesn't look.
    if (_bridgeLive()) return ChromeExtensionState.ready;
    return chromiumUserDataDirs(_home).any(_hasExtension)
        ? ChromeExtensionState.hostPending
        : ChromeExtensionState.missing;
  }

  /// Whether any browser is holding the bridge open.
  bool _bridgeLive() {
    final dir = Directory(bridgeDir);
    if (!dir.existsSync()) return false;
    try {
      return dir.listSync().any((entry) => entry.path.endsWith('.sock'));
    } on FileSystemException {
      // Another user's directory, which is not this user's browser.
      return false;
    }
  }

  /// Whether any profile under [dataDir] carries the extension. Profiles are
  /// `Default`, `Profile 1`, … and a user can have the extension in one and not
  /// another, so this asks the whole browser rather than a named profile.
  bool _hasExtension(String dataDir) {
    final root = Directory(dataDir);
    if (!root.existsSync()) return false;
    for (final child in root.listSync().whereType<Directory>()) {
      final extension = Directory(
        '${child.path}/Extensions/$kClaudeInChromeExtensionId',
      );
      if (extension.existsSync()) return true;
    }
    return false;
  }
}

/// The probe seam. A plain provider so tests can point it at a temp home.
///
/// The *probe* is the provider, not its answer: a cached
/// `Provider<ChromeExtensionState>` would read the disk once and hold that
/// verdict for the rest of the session, so a user who installed the extension —
/// or restarted Chrome after the manifest was written — would keep being told
/// the lane is shut. Callers ask [detect] per turn instead; it is one directory
/// listing on the connected path.
final chromeExtensionProbeProvider = Provider<ChromeExtensionProbe>(
  (ref) => ChromeExtensionProbe(),
);
