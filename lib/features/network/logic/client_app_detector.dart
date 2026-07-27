import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/host_environment.dart';

/// A local AI client the user can point at a grid. Each one has a config file we
/// know how to write ("Apply for me") and a download page for when it's absent.
///
/// Declaration order is the guide's tab order — Hermes leads, then OpenClaw
/// beside it, then Codex and Buzz.
enum ClientApp { hermes, openClaw, codex, buzz }

extension ClientAppX on ClientApp {
  /// Whether the guide offers this client at all — one switch, so an app can be
  /// hidden in a single place rather than through a picker or a default that
  /// forgot about it.
  ///
  /// **Codex** ships to everyone. It only talks to the Responses API (codex ≥
  /// 0.141 rejects `wire_api = "chat"`), which not every relay serves yet — so
  /// the tab is always offered and the *grid* decides whether it works, per
  /// grid. Hiding it outside debug was the blunt version of the same honesty:
  /// it also hid Codex from the grids that can already answer it.
  /// TODO(BE): the panel still walks the setup on a relay with no
  /// `/v1/responses`. Wire [agentRunsOnGridProvider] into it so such a grid
  /// says so, instead of handing out steps that end in a 404.
  ///
  /// **OpenClaw** is offered too — an agent client the guide points at a grid
  /// by writing `~/.openclaw/openclaw.json` (its config writer and snippet are
  /// the same shape as the others'), sitting beside Hermes as another local
  /// agent.
  ///
  /// **Buzz** ships to everyone. Its agents pick a provider/model per agent, so
  /// pointing it at a grid means writing the grid as the *default* provider in
  /// [kBuzzConfigRelPath] — one file, every agent, no builtin disturbed.
  bool get isSelectable => switch (this) {
    ClientApp.hermes => true,
    ClientApp.openClaw => true,
    ClientApp.codex => true,
    ClientApp.buzz => true,
  };
}

/// Home-relative path to Buzz's global agent config — the single JSON file that
/// sets the default `provider` / `model` / `env_vars` for every Buzz agent.
///
/// This, not `managed-agents.json`, is the "Set up for me" write target: it
/// leaves the builtin agents untouched and the running desktop rewrites the
/// per-agent file (not this one) on agent-lifecycle events. Shared by the
/// detector (as the "installed" signal's parent), the guide (paste target) and
/// [ClientAppConfigurator]. Buzz stores `provider: "openai-compat"`, a top-level
/// `model`, and the `OPENAI_COMPAT_*` pair under `env_vars` here.
const String kBuzzConfigRelPath =
    'Library/Application Support/xyz.block.buzz.app/agents/'
    'global-agent-config.json';

/// The clients the guide may show, in [ClientApp.values] order — everything the
/// build is allowed to offer (see [ClientAppX.isSelectable]). The one list the
/// picker and the detector both walk, so a hidden app can't sneak back in as an
/// "Installed" chip or the default selection.
final List<ClientApp> kSelectableClientApps = List.unmodifiable(
  ClientApp.values.where((app) => app.isSelectable),
);

/// Static facts about a [ClientApp] — display name, where to get it, and where
/// its config lives. One source of truth so the dialog, detector and
/// configurator agree on names/paths instead of re-typing them.
class ClientAppInfo {
  const ClientAppInfo({
    required this.app,
    required this.name,
    required this.downloadUrl,
    required this.configDir,
    required this.configPath,
    required this.executable,
  });

  final ClientApp app;
  final String name;

  /// Public download / install page, opened when the app isn't installed.
  final String downloadUrl;

  /// Home-relative directory whose presence signals "installed" (e.g.
  /// `.openclaw`).
  final String configDir;

  /// Human path shown in the guide (e.g. `~/.openclaw/openclaw.json`).
  final String configPath;

  /// CLI executable name to look for on PATH as a second install signal.
  final String executable;
}

/// The known clients, keyed by [ClientApp]. Ordered by [ClientApp.values].
const Map<ClientApp, ClientAppInfo> kClientApps = {
  ClientApp.hermes: ClientAppInfo(
    app: ClientApp.hermes,
    name: 'Hermes',
    downloadUrl: 'https://hermes-agent.nousresearch.com/',
    configDir: '.hermes',
    configPath: '~/.hermes/config.yaml',
    executable: 'hermes',
  ),
  ClientApp.openClaw: ClientAppInfo(
    app: ClientApp.openClaw,
    name: 'OpenClaw',
    downloadUrl: 'https://docs.openclaw.ai/install',
    configDir: '.openclaw',
    configPath: '~/.openclaw/openclaw.json',
    executable: 'openclaw',
  ),
  ClientApp.codex: ClientAppInfo(
    app: ClientApp.codex,
    name: 'Codex',
    downloadUrl: 'https://openai.com/vi-VN/codex/get-started/',
    configDir: '.codex',
    configPath: '~/.codex/config.toml',
    executable: 'codex',
  ),
  ClientApp.buzz: ClientAppInfo(
    app: ClientApp.buzz,
    name: 'Buzz',
    downloadUrl: 'https://github.com/block/buzz',
    // Buzz keeps its data under the app-support bundle, not a home dotfile — its
    // presence is the "installed" signal (alongside /Applications/Buzz.app and
    // the `buzz` CLI on PATH).
    configDir: 'Library/Application Support/xyz.block.buzz.app',
    configPath: '~/$kBuzzConfigRelPath',
    executable: 'buzz',
  ),
};

/// Where Codex reads a key from: it has no `api_key` config field, so the
/// provider names an environment variable ([gridApiKeyEnv]) and Codex loads it
/// from this dotenv file — which is why the Codex setup writes two files.
const String kCodexEnvPath = '~/.codex/.env';

/// A short, plain-language walkthrough to wire [info]'s app to a grid: a [title]
/// and numbered [steps]. Hermes has a friendly in-app flow (Settings → Model →
/// Custom endpoint), so we walk that GUI; a file-based client is wired by pasting
/// the config block. Either way the user drops the Base URL + Token (shown as
/// copyable fields in the panel) into the blanks — so the steps name those two.
/// Codex takes two files (config + key), so its steps name both.
({String title, List<String> steps}) appSetupGuide(
  ClientAppInfo info,
) => switch (info.app) {
  ClientApp.codex => (
    title: 'Add it to ${info.name}',
    steps: [
      'Open ${info.configPath} (create it if it isn\'t there)',
      'Paste the first block below — it points Codex at this grid',
      'Put the second block in $kCodexEnvPath — Codex reads your key there',
      'Run codex again in your terminal; it now answers with this grid',
    ],
  ),
  ClientApp.hermes => (
    title: 'Set it up in Hermes Agent',
    steps: const [
      'Open Hermes Agent, then Settings (gear icon, top-right)',
      'Under Model, choose "Custom endpoint", then "Set up Custom endpoint"',
      'Pick "Local / custom endpoint"',
      'Paste the Base URL above into the endpoint field',
      'Paste the API key into the "API key" field',
      'Click Connect',
    ],
  ),
  ClientApp.openClaw => (
    title: 'Add it to ${info.name}',
    steps: [
      'Open ${info.configPath}',
      'Paste the block below (or fill Base URL + API key yourself)',
      'Restart ${info.name}',
    ],
  ),
  // Buzz rewrites this file itself while running, so the paste path leads with
  // quitting it — otherwise the running app overwrites the edit. The block sets
  // the grid as the default model for every Buzz agent.
  ClientApp.buzz => (
    title: 'Add it to ${info.name}',
    steps: [
      'Quit ${info.name} first — it rewrites this file while it runs',
      'Open ${info.configPath} (create it if it isn\'t there)',
      'Paste the block below — it makes this grid the default model '
          'for every ${info.name} agent',
      'Reopen ${info.name}; its agents now answer with this grid',
    ],
  ),
};

/// Detects which known client apps look installed on this machine. "Installed" =
/// the app's config directory exists under `$HOME`, **or** its CLI is on the
/// augmented PATH, **or** (macOS) an app bundle of that name sits in
/// `/Applications`. All checks are local filesystem lookups — offline and
/// deterministic, so detection is safe to run when the guide opens. The checks
/// are injectable so the logic is unit-tested without touching the real disk.
class ClientAppDetector {
  ClientAppDetector({
    String? home,
    bool Function(String path)? dirExists,
    String? Function(String name)? findExecutable,
  }) : _home = home ?? GridPaths.userHome,
       _dirExists = dirExists ?? _defaultDirExists,
       _findExecutable = findExecutable ?? HostEnvironment.findExecutable;

  final String _home;
  final bool Function(String path) _dirExists;
  final String? Function(String name) _findExecutable;

  bool isInstalled(ClientApp app) {
    final info = kClientApps[app]!;
    // Config dir first: cheap and true for anyone who's run the app once, so we
    // usually skip the PATH probe (which can spawn a login shell on first use).
    if (_dirExists('$_home/${info.configDir}')) return true;
    if (Platform.isMacOS && _dirExists('/Applications/${info.name}.app')) {
      return true;
    }
    return _findExecutable(info.executable) != null;
  }

  /// The installed apps this build may offer, in [ClientApp.values] order — an
  /// app the guide can't show is never reported as installed.
  Set<ClientApp> detect() => {
    for (final app in kSelectableClientApps)
      if (isInstalled(app)) app,
  };

  static bool _defaultDirExists(String path) => Directory(path).existsSync();
}

/// Which client apps are installed. Auto-disposed so a fresh scan runs each time
/// the guide opens (the user may install an app between opens).
final installedClientAppsProvider = Provider.autoDispose<Set<ClientApp>>(
  (ref) => ClientAppDetector().detect(),
);
