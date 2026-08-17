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

/// The native messaging host Claude Code installs the first time it runs with
/// `--chrome`. The extension and the CLI never speak directly: Chrome launches
/// this host (`~/.claude/chrome/chrome-native-host`) and relays between them.
const String kClaudeCodeNativeHost =
    'com.anthropic.claude_code_browser_extension';

/// How far this computer is from letting a turn drive the user's browser.
///
/// Three states rather than a bool because the middle one is the common case
/// and has a different answer: Chrome reads native messaging host manifests
/// **at startup**, so the run that installs the manifest is never the run that
/// can use it — the browser has to be restarted first.
enum ChromeExtensionState {
  /// No Chromium browser on this computer carries the extension.
  missing,

  /// The extension is there, but no browser has the host manifest yet (or has
  /// one written after it started). Browser calls fail until Chrome restarts.
  hostPending,

  /// Extension and host manifest both in place.
  ready,
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

/// Reads the two things on disk that decide whether the extension lane is open:
/// the extension itself, and Claude Code's native messaging host manifest.
///
/// A file probe rather than a CLI call — `claude` has no non-interactive way to
/// report Chrome status (`/chrome` is a slash command inside a session), and the
/// app needs the answer before it builds the argv for a turn.
class ChromeExtensionProbe {
  ChromeExtensionProbe({String? userHome})
    : _home = userHome ?? GridPaths.userHome;

  final String _home;

  ChromeExtensionState detect() {
    var sawExtension = false;
    for (final dir in chromiumUserDataDirs(_home)) {
      if (!_hasExtension(dir)) continue;
      sawExtension = true;
      if (_hasHost(dir)) return ChromeExtensionState.ready;
    }
    return sawExtension
        ? ChromeExtensionState.hostPending
        : ChromeExtensionState.missing;
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

  bool _hasHost(String dataDir) => File(
    '$dataDir/NativeMessagingHosts/$kClaudeCodeNativeHost.json',
  ).existsSync();
}

/// The probe seam. A plain provider so tests can point it at a temp home.
///
/// The *probe* is the provider, not its answer: a cached
/// `Provider<ChromeExtensionState>` would read the disk once and hold that
/// verdict for the rest of the session, so a user who installed the extension —
/// or restarted Chrome after the manifest was written — would keep being told
/// the lane is shut. Callers ask [detect] per turn instead; it is two
/// `existsSync` calls per browser.
final chromeExtensionProbeProvider = Provider<ChromeExtensionProbe>(
  (ref) => ChromeExtensionProbe(),
);
