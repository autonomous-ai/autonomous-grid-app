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
