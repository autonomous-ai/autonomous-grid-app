/// The oldest `grid` the app can drive.
///
/// 0.2.0 is where the CLI stopped needing Homebrew: `engine install` downloads a
/// pinned llama.cpp build, and `agent install` was added. The app now depends on
/// both, so an older CLI can't do what the app asks of it — `grid agent install`
/// doesn't exist there, and `engine install` dead-ends on a Mac with no Homebrew.
/// Better to say so than to fail three screens later in the installer's voice.
const minimumGridVersion = (major: 0, minor: 2, patch: 0);

/// The version numbers in a `grid --version` line (`grid 0.2.0`), or null when
/// the line carries none. A build without package metadata prints no version at
/// all — that isn't an error (see [PreflightService]), so callers treat null as
/// "unknown", not "too old".
({int major, int minor, int patch})? parseGridVersion(String output) {
  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(output);
  if (match == null) return null;
  return (
    major: int.parse(match.group(1)!),
    minor: int.parse(match.group(2)!),
    patch: int.parse(match.group(3)!),
  );
}

/// Whether [version] is at least [minimumGridVersion]. A null (unreadable)
/// version passes: it means the CLI printed no metadata, which a source checkout
/// legitimately does, and blocking those would be worse than letting the command
/// itself fail with its own message.
bool isSupportedGridVersion(({int major, int minor, int patch})? version) {
  if (version == null) return true;
  const min = minimumGridVersion;
  if (version.major != min.major) return version.major > min.major;
  if (version.minor != min.minor) return version.minor > min.minor;
  return version.patch >= min.patch;
}

/// What to tell the user when their `grid` is too old to drive.
String outdatedGridMessage(String? version) {
  const min = minimumGridVersion;
  final found = version == null ? '' : ' (found $version)';
  return 'The Grid helper is out of date$found. Grid needs '
      '${min.major}.${min.minor}.${min.patch} or newer to set up the engine '
      'without Homebrew. Update Grid, then check again.';
}
