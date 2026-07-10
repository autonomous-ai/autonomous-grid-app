import 'host_environment.dart';

/// Locates the `codex` executable (OpenAI's coding agent), used to back the
/// Chat tab's experimental Agent mode.
///
/// Unlike `grid`, codex ships no bundled sidecar — the user installs it once via
/// `brew install --cask codex`. Homebrew drops it in `/opt/homebrew/bin` (Apple
/// Silicon) or `/usr/local/bin` (Intel), both of which [HostEnvironment] already
/// puts on the augmented `PATH`, so a Finder-launched GUI app finds it there even
/// though its minimal inherited `PATH` would miss it.
class CodexResolver {
  CodexResolver({String? Function(String)? lookup})
    : _lookup = lookup ?? HostEnvironment.findExecutable;

  final String? Function(String) _lookup;

  /// Absolute path to a usable `codex`, or null when it isn't installed.
  String? resolve() => _lookup('codex');
}
