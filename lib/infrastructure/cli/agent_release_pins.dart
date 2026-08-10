/// Pinned release builds for the agents the app installs itself, verified by
/// SHA-256 before anything runs.
///
/// **This is a copy of the `grid` CLI's installers** (`autonomous-grid`
/// `shared/agent/installer.py` and `codex_installer.py`). The app now installs
/// agents without the CLI, so the pinned versions and hashes live here too — and
/// **the two must be kept in sync**: when the CLI bumps a version, bump it here
/// or the app downloads an archive whose hash no longer matches and every
/// install fails. `agent_release_pins_test` checks every platform has an entry
/// so a missing one is a CI failure, not a runtime surprise.
///
/// TODO(BE): fold this back to one source — e.g. have the CLI print its install
/// spec (`grid agent spec --json`) and read it here — so a version can't drift.
library;

/// A downloadable, hash-verified release asset.
typedef ReleaseBuild = ({String url, String sha256});

// ─── uv (Hermes' installer) ────────────────────────────────────────────────
// Hermes ships as a Python package; the app fetches this pinned `uv` and lets it
// install Hermes with its own private CPython — no package manager, no admin.

const String kUvRelease = '0.11.28';

/// SHA-256 per `<arch>-<os>` target, mirroring UV_BUILDS in the CLI.
const Map<String, String> _uvSha256 = {
  'aarch64-apple-darwin':
      '33540eb7c883ab857eff79bd5ac2aa31fe27b595abecb4a9c003a2c998447232',
  'x86_64-apple-darwin':
      '2ad79983127ffca7d77b77ce6a24278d7e4f7b817a1acf72fea5f8124b4aac5e',
  'x86_64-pc-windows-msvc':
      '0a23463216d09c6a72ff80ef5dc5a795f07dc1575cb84d24596c2f124a441b7b',
  'aarch64-pc-windows-msvc':
      '3248109afad3ec59baad299d324ff53de17e2d9a3b3e21580ffd26744b11e036',
  'x86_64-unknown-linux-gnu':
      'e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224',
  'aarch64-unknown-linux-gnu':
      '03e9fe0a81b0718d0bc84625de3885df6cc3f89a8b6af6121d6b9f6113fb6533',
};

/// The pinned `uv` build for [target], or null when there's no build for it —
/// uv ships Windows as a `.zip`, every other platform as a `.tar.gz`.
ReleaseBuild? uvBuildFor(String target) {
  final sha = _uvSha256[target];
  if (sha == null) return null;
  final ext = target.contains('windows') ? 'zip' : 'tar.gz';
  return (
    url:
        'https://github.com/astral-sh/uv/releases/download/$kUvRelease/'
        'uv-$target.$ext',
    sha256: sha,
  );
}

// ─── Codex ──────────────────────────────────────────────────────────────────
// Codex ships a prebuilt binary per OS/arch on GitHub — no npm, no package
// manager. The app fetches the pinned archive for this machine and drops the
// binary into ~/.grid/bin.

const String kCodexRelease = 'rust-v0.144.6';

/// Asset name + SHA-256 per target, mirroring CODEX_BUILDS in the CLI. Windows
/// ships as `.exe.zip`, the Unixes as `.tar.gz`; Linux takes the static musl
/// build so it runs without a matching system glibc.
const Map<String, ({String asset, String sha256})> _codexBuilds = {
  'aarch64-apple-darwin': (
    asset: 'codex-aarch64-apple-darwin.tar.gz',
    sha256: '023590f828bc9507ac61132ee35e74d3c5d33fb5ba3e1ca4fc2e013a2f71a3d7',
  ),
  'x86_64-apple-darwin': (
    asset: 'codex-x86_64-apple-darwin.tar.gz',
    sha256: '763c81a56ba24a4f6c2fd256ed7ee1775caeccd22537d28887de8f6864ac5947',
  ),
  'x86_64-pc-windows-msvc': (
    asset: 'codex-x86_64-pc-windows-msvc.exe.zip',
    sha256: '0048604040fe61fa6163238fb0fcbda79e6bc465a8eecafc8f5ae8e4b69f77fd',
  ),
  'aarch64-pc-windows-msvc': (
    asset: 'codex-aarch64-pc-windows-msvc.exe.zip',
    sha256: 'de13275b7e31731474e0c1bce68ceaa07ba85ceecf63a1a4a9d5f7f58275b2d2',
  ),
  'x86_64-unknown-linux-musl': (
    asset: 'codex-x86_64-unknown-linux-musl.tar.gz',
    sha256: '6a9def51a0ad8cea6684d8eb3bf033c89f33e3bc5cfe492f1a1e0a718451a1c6',
  ),
  'aarch64-unknown-linux-musl': (
    asset: 'codex-aarch64-unknown-linux-musl.tar.gz',
    sha256: '8eddae5e6c009dff9ba51ae1bfe3bdd9ff4c1ccc93a48cc6860db1cd9fdf11be',
  ),
};

/// The pinned Codex build for [target], or null when there's no build for it.
ReleaseBuild? codexBuildFor(String target) {
  final build = _codexBuilds[target];
  if (build == null) return null;
  return (
    url:
        'https://github.com/openai/codex/releases/download/$kCodexRelease/'
        '${build.asset}',
    sha256: build.sha256,
  );
}

// ─── Node (Pi's runtime) ──────────────────────────────────────────────────────
// Pi ships only as an npm package, so — unlike Codex's single binary — the app
// fetches this pinned Node.js toolchain into `~/.grid/node` and lets its own npm
// install Pi with `--prefix ~/.grid`. Same self-contained story as Hermes' uv:
// a private runtime under `~/.grid`, hash-verified, no system Node, no admin.

const String kNodeRelease = 'v22.19.0';

/// The npm package the app installs Pi from, and the version it pins — mirroring
/// the CLI's own installer. `pi --list-models` / `pi --mode json` come from here.
const String kPiPackage = '@earendil-works/pi-coding-agent';
const String kPiRelease = '0.84.1';

/// The Node platform slug (`<os>-<arch>`) per `<arch>-<os>` target — Node's dist
/// archives are named `node-<release>-<slug>.<ext>`. Node uses the gnu Linux
/// build (not musl), so the app resolves its target with `linuxMusl: false`.
const Map<String, ({String slug, String sha256})> _nodeBuilds = {
  'aarch64-apple-darwin': (
    slug: 'darwin-arm64',
    sha256: 'c59006db713c770d6ec63ae16cb3edc11f49ee093b5c415d667bb4f436c6526d',
  ),
  'x86_64-apple-darwin': (
    slug: 'darwin-x64',
    sha256: '3cfed4795cd97277559763c5f56e711852d2cc2420bda1cea30c8aa9ac77ce0c',
  ),
  'aarch64-unknown-linux-gnu': (
    slug: 'linux-arm64',
    sha256: 'd32817b937219b8f131a28546035183d79e7fd17a86e38ccb8772901a7cd9009',
  ),
  'x86_64-unknown-linux-gnu': (
    slug: 'linux-x64',
    sha256: 'd36e56998220085782c0ca965f9d51b7726335aed2f5fc7321c6c0ad233aa96d',
  ),
  'aarch64-pc-windows-msvc': (
    slug: 'win-arm64',
    sha256: 'e4a7336010d58ff35b53d9dd5869095c56089c70913cf22508cf8183593e56b2',
  ),
  'x86_64-pc-windows-msvc': (
    slug: 'win-x64',
    sha256: 'ea3fad0e67a991d8477d8c01344b56e69c676ccb733f065b22436994b1253f86',
  ),
};

/// The pinned Node build for [target], or null when there's no build for it —
/// Node ships Windows as a `.zip`, every other platform as a `.tar.gz`.
ReleaseBuild? nodeBuildFor(String target) {
  final build = _nodeBuilds[target];
  if (build == null) return null;
  final ext = build.slug.startsWith('win') ? 'zip' : 'tar.gz';
  return (
    url:
        'https://nodejs.org/dist/$kNodeRelease/'
        'node-$kNodeRelease-${build.slug}.$ext',
    sha256: build.sha256,
  );
}

/// Every uv target this build knows — the coverage test asserts the platform
/// matrix stays complete.
Iterable<String> get uvTargets => _uvSha256.keys;

/// Every Codex target this build knows.
Iterable<String> get codexTargets => _codexBuilds.keys;

/// Every Node target this build knows — the coverage test asserts Pi can be
/// installed on the same platform matrix as the other agents.
Iterable<String> get nodeTargets => _nodeBuilds.keys;
