/// Pinned Git builds the app installs when this computer has none, verified by
/// SHA-256 before anything runs.
///
/// **Deliberately not in `agent_release_pins.dart`.** That file is a hand-kept
/// copy of the `grid` CLI's own installers, and its `TODO(BE)` is to fold the two
/// back into one source. Git has no counterpart on the CLI side, so filing it
/// there would create a third kind of pin — one that can never be synced,
/// because there is nothing to sync it with — and would keep that TODO from ever
/// closing.
///
/// The build is [desktop/dugite-native](https://github.com/desktop/dugite-native):
/// the Git that GitHub Desktop embeds, built to be unpacked anywhere rather than
/// installed. It is the only option that fits how the app installs everything
/// else — a hash-verified tarball into `~/.grid`, no admin rights, no package
/// manager, nothing to click.
///
/// Two things about it are not free, and both are handled elsewhere rather than
/// hidden:
///  * It is not upstream Git, and its README says it is "not intended to be
///    installed by end users" — so the version is pinned hard and bumped by hand.
///  * It relocates through the environment, not the binary: a spawned `git` needs
///    `GIT_EXEC_PATH`, `GIT_CONFIG_SYSTEM` and `GIT_TEMPLATE_DIR`, or `git clone`
///    over HTTPS dies with `'remote-https' is not a git command`. See
///    [HostEnvironment.gitEnvironment].
library;

import 'dart:ffi' show Abi;

import 'agent_release_pins.dart' show ReleaseBuild;

/// The dugite-native release these pins name. Bumping this means re-fetching
/// every hash below — the assets carry the git SHA in their filename, so a
/// version bump changes the URL as well as the digest.
const String kGitRelease = 'v2.53.0-3';

/// The Git version inside [kGitRelease], for the log line and the version gate.
const String kGitVersion = '2.53.0';

/// The lowest Git the app will accept from the machine before installing its
/// own. A Git that runs but is too old fails later, inside a `clone`, where the
/// error belongs to git rather than to us — the same reason
/// `isSupportedGridVersion` exists for the CLI.
const ({int major, int minor}) kMinimumGitVersion = (major: 2, minor: 20);

/// Asset stem + SHA-256 per platform. The stem carries dugite's build SHA, which
/// is why the full name is pinned rather than rebuilt from [kGitRelease].
const Map<Abi, ({String asset, String sha256})> _builds = {
  Abi.macosArm64: (
    asset: 'dugite-native-v2.53.0-f49d009-macOS-arm64.tar.gz',
    sha256: 'e561cfc80c755e6f3e938653e81efcd025c9827a5b76dd42778b1159b3fab437',
  ),
  Abi.macosX64: (
    asset: 'dugite-native-v2.53.0-f49d009-macOS-x64.tar.gz',
    sha256: 'caf27c36b8834969550535bcd5e58186f970e080d1e175e76d9c1de3aac409ed',
  ),
  Abi.linuxX64: (
    asset: 'dugite-native-v2.53.0-f49d009-ubuntu-x64.tar.gz',
    sha256: 'b3a85433c8dfde76d21b90938ad2f971653deff4340b1b4d347258c63250eafc',
  ),
  Abi.linuxArm64: (
    asset: 'dugite-native-v2.53.0-f49d009-ubuntu-arm64.tar.gz',
    sha256: 'd562ad433ed0dc1907f44a92fc701597bc577c48d07fe69ee7adddfee836ef4c',
  ),
  // Windows is deliberately absent, so the background installer no-ops there
  // rather than half-working. It needs a different asset and a different unpack:
  // dugite's Windows build repackages MinGit, which has no `bin\bash.exe` — and
  // that file is exactly what `HostEnvironment.gitBashBeside` looks for to fill
  // `HERMES_GIT_BASH_PATH`. The asset that does carry it is PortableGit, a
  // self-extracting `.7z.exe` that has to be run rather than unzipped. Until
  // that lands, a Windows machine keeps using whatever Git the user installed.
};

/// The pinned Git build for [abi], or null when this platform has none — the
/// caller then leaves the machine's own Git (if any) alone.
ReleaseBuild? gitBuildFor(Abi abi) {
  final build = _builds[abi];
  if (build == null) return null;
  return (
    url:
        'https://github.com/desktop/dugite-native/releases/download/'
        '$kGitRelease/${build.asset}',
    sha256: build.sha256,
  );
}

/// Every platform these pins cover — the coverage test asserts the matrix stays
/// complete as platforms are added.
Iterable<Abi> get gitTargets => _builds.keys;
