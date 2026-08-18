import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';
import 'chrome_extension_probe.dart';
import 'text_file.dart';

/// The flag that turns Claude Code into the process Chrome talks to. Hidden
/// from `--help`, so it is measured rather than read: run on 2.1.183 it prints
/// `Creating socket listener: /tmp/claude-mcp-browser-bridge-<user>/<pid>.sock`
/// and waits — which is the whole bridge (see [ChromeExtensionProbe]).
const String kClaudeNativeHostFlag = '--chrome-native-host';

/// Where the wrapper script Chrome executes lives, under the user's home.
const String kClaudeHostScriptPath = '.claude/chrome/chrome-native-host';

/// What was on disk after a pass, and whether this pass is what put it there.
///
/// [changed] is the half the user needs: Chrome reads native messaging host
/// manifests **at startup**, so a connection written now is a connection that
/// works after the next restart, and saying "connected" without saying that
/// would be a green tick over a browser that still answers nothing (§5).
typedef ChromeHostInstall = ({List<String> browsers, bool changed});

/// Puts Claude Code's browser connection on disk, the way the Claude desktop
/// app does: two small files, no browser opened and no model asked.
///
/// **Why files and not a turn.** The connection is a native messaging host —
/// a manifest in each browser's user-data directory naming an executable
/// Chrome may launch, plus that executable. Claude Code writes both on its
/// first `--chrome` run, which is why this app used to spend a real turn to
/// get them (`ChromeSetupController` ran a throwaway prompt). Nothing about
/// them needs a model: `/Applications/Claude.app` ships the same pair and
/// refreshes its manifest every launch — measured here, its manifest is newer
/// than the bundle it came from.
///
/// The manifest is written for every Chromium browser on the machine, extension
/// or no extension, and that is the point: it ends the wait where the app would
/// not connect until the extension was installed and the extension was no use
/// until the app connected. Install the extension whenever — the connection is
/// already there.
class ChromeHostInstaller {
  ChromeHostInstaller({required String claudeBinary, String? userHome})
    : _binary = claudeBinary,
      _home = userHome ?? GridPaths.userHome;

  final String _binary;
  final String _home;

  /// Whether this platform keeps native messaging hosts in files at all.
  ///
  /// Windows keeps them in the registry (`HKCU\Software\<vendor>\
  /// NativeMessagingHosts\`), which nothing here writes — so it is refused up
  /// front rather than reported as a machine with no browsers on it.
  static bool get supported => Platform.isMacOS || Platform.isLinux;

  String get _scriptPath => '$_home/$kClaudeHostScriptPath';

  /// Write what is missing and leave what is already right.
  ///
  /// Runs on every launch, so it is cheap and idempotent: three `existsSync`
  /// calls and a string compare per browser on the common path, where nothing
  /// has changed and nothing is written.
  Future<ChromeHostInstall> install() async {
    await _ensureScript();
    final manifest = claudeChromeHostManifest(hostPath: _scriptPath);
    final browsers = <String>[];
    var changed = false;
    for (final dir in chromiumUserDataDirs(_home)) {
      if (!Directory(dir).existsSync()) continue;
      browsers.add(dir);
      if (_writeManifest(dir, manifest)) changed = true;
    }
    // Only the manifest counts. Chrome reads *that* at startup, while it runs
    // the wrapper script per connection — so a script rewritten behind an
    // unchanged manifest is already live, and counting it would ask for a
    // browser restart that fixes nothing.
    return (browsers: browsers, changed: changed);
  }

  /// The wrapper Chrome runs. Written when it is missing, and rewritten when
  /// the binary it names is gone — Claude Code writes this pointing at the
  /// *versioned* file it is running from (`…/versions/2.1.183`), so its own
  /// updates leave it aimed at a version that has been pruned and a browser
  /// whose calls die with no visible cause. This one names the launcher.
  Future<void> _ensureScript() async {
    final file = File(_scriptPath);
    if (file.existsSync() && !_scriptIsStale(_scriptPath)) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      claudeChromeHostScript(claudeBinary: _binary),
      flush: true,
    );
    // Dart cannot set a mode; a manifest pointing at a file Chrome may not
    // execute is the same as no connection at all.
    await Process.run('/bin/chmod', ['755', _scriptPath]);
  }

  /// Whether the script on disk points at something that isn't there any more.
  /// Unreadable counts as stale: a script this app cannot check is one it would
  /// rather replace with one it wrote.
  bool _scriptIsStale(String path) {
    final text = readTextFileNow(path);
    if (text == null) return true;
    final target = claudeHostScriptTarget(text);
    return target == null || !File(target).existsSync();
  }

  /// True when [dir] did not already carry exactly this manifest.
  bool _writeManifest(String dir, String manifest) {
    final path = '$dir/NativeMessagingHosts/$kClaudeCodeNativeHost.json';
    if (readTextFileNow(path) == manifest) return false;
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(manifest, flush: true);
    return true;
  }
}

/// The manifest Chrome reads to learn that this browser extension may launch
/// Claude Code.
///
/// Byte-for-byte what Claude Code writes itself — two-space indent, and **no
/// trailing newline** — which is not a cosmetic match: the pass rewrites a
/// manifest whose bytes differ, and a manifest rewritten is a Chrome restart
/// asked for. One newline of drift would have meant every machine Claude Code
/// had already set up being told, once, to restart a browser for nothing.
String claudeChromeHostManifest({required String hostPath}) =>
    const JsonEncoder.withIndent('  ').convert({
      'name': kClaudeCodeNativeHost,
      'description': 'Claude Code Browser Extension Native Host',
      'path': hostPath,
      'type': 'stdio',
      'allowed_origins': ['chrome-extension://$kClaudeInChromeExtensionId/'],
    });

/// The wrapper Chrome executes. It exists because a native messaging host must
/// be a single executable path, and Claude Code is reached with a flag.
String claudeChromeHostScript({required String claudeBinary}) =>
    '#!/bin/sh\n'
    '# Chrome native messaging host for Claude Code.\n'
    '# Written by Grid at launch — Chrome runs this and speaks to Claude Code\n'
    '# over its stdin and stdout.\n'
    'exec "$claudeBinary" $kClaudeNativeHostFlag\n';

/// The binary a host wrapper runs, or null when [script] doesn't name one.
/// Pure, and unit-tested, because it decides whether a working connection gets
/// overwritten: read one line wrong and every launch rewrites a good file.
String? claudeHostScriptTarget(String script) {
  for (final line in const LineSplitter().convert(script)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('exec ')) continue;
    final open = trimmed.indexOf('"');
    if (open == -1) continue;
    final close = trimmed.indexOf('"', open + 1);
    if (close == -1) continue;
    return trimmed.substring(open + 1, close);
  }
  return null;
}
