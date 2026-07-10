import 'dart:io';

/// Resolves locations under `~/.grid`, mirroring the CLI's `paths.py`.
///
/// The CLI honours `GRID_HOME`, falling back to `~/.grid`. Everything the app
/// reads (credentials, per-network config, models, outputs) lives here — this
/// directory is the single source of truth (see CLI_Integration_Contract §1).
class GridPaths {
  const GridPaths._();

  /// The OS home directory (`$HOME` / `%USERPROFILE%`). Config for *other* tools
  /// the app points at a grid (OpenClaw, Hermes) lives here, outside `~/.grid`.
  static String get userHome =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;

  static Directory get home {
    final override = Platform.environment['GRID_HOME'];
    return Directory(
      override != null && override.isNotEmpty ? override : '$userHome/.grid',
    );
  }

  static File get deviceFile => File('${home.path}/device.toml');

  static File get credentialsFile => File('${home.path}/credentials.toml');

  /// Machine-local API-engine key store (`~/.grid/api_keys.toml`, `0o600`) — one
  /// vendor key per service kind, written by `grid join --api <kind>`. Separate
  /// from [credentialsFile] on purpose: `grid logout` clears credentials but
  /// leaves this (the key belongs to the vendor account, not the sign-in). The
  /// app only reads whether a kind has a key, to skip re-asking (ADR 0012).
  static File get apiKeysFile => File('${home.path}/api_keys.toml');

  /// The merged CLI's mode pointer + per-mode active grid
  /// (`{"mode": …, "active": {"local": …, "remote": …}}`). New in dual-mode: the
  /// active selection moved here out of `credentials.toml` (CLI shared/state.py).
  static File get stateFile => File('${home.path}/state.json');

  static Directory get networksDir => Directory('${home.path}/networks');

  static Directory networkDir(String networkId) =>
      Directory('${networksDir.path}/$networkId');

  static File networkConfigFile(String networkId) =>
      File('${networkDir(networkId).path}/config.toml');

  static File networkServerLog(String networkId) =>
      File('${networkDir(networkId).path}/server.log');

  static Directory get modelsDir => Directory('${home.path}/models');

  static Directory get outputsDir => Directory('${home.path}/outputs');

  /// Saved Chat conversations, one JSON file per conversation
  /// (`~/.grid/app/chats/<id>.json`). App-owned — the CLI never reads or writes
  /// here; it lives under `app/` to stay clearly namespaced away from CLI state.
  static Directory get chatsDir => Directory('${home.path}/app/chats');

  static File chatFile(String id) => File('${chatsDir.path}/$id.json');

  /// The Chat tab's remembered selections (last grid, model, agent backend), so
  /// reopening the app restores them. App-owned — the CLI never touches it.
  static File get chatPrefsFile => File('${home.path}/app/chat_prefs.json');

  /// Working directory for the Chat tab's experimental Agent mode (codex). The
  /// agent runs read-only here so its file tools have a stable, app-owned root
  /// instead of pointing at the user's home. App-owned — the CLI never touches
  /// it.
  static Directory get codexWorkspaceDir =>
      Directory('${home.path}/app/codex-workspace');

  /// The CLI's own log directory (`~/.grid/logs`, e.g. `llama_llm_*.log`). The
  /// app drops its own diagnostic logs here too so everything a user might send
  /// us to debug lives in one place.
  static Directory get logsDir => Directory('${home.path}/logs');

  /// Durable transcript of the background node-setup / auto-install run, written
  /// by the app itself (not the CLI). The in-app log is in-memory only and gone
  /// once the app closes; this file survives a failed silent install so it can
  /// be debugged after the fact.
  static File get nodeSetupLog => File('${logsDir.path}/app_node_setup.log');

  /// Durable transcript of every `grid` CLI call the app makes (command,
  /// streamed output, outcome). The in-app Debug tab is a capped in-memory ring
  /// buffer gone once the app closes; this file survives so a user can send it
  /// to us to debug a failed command after the fact.
  static File get cliLog => File('${logsDir.path}/app_cli.log');

  /// The app's own narrative timeline: lifecycle milestones, every CLI/HTTP call
  /// as a one-liner, and every uncaught error with its stack trace. This is the
  /// first file to read to understand what the app was doing and where it broke;
  /// [cliLog] holds the deeper per-command CLI output.
  static File get appLog => File('${logsDir.path}/app.log');

  /// Where `grid llama.cpp install` links the engine (provider_runtime
  /// paths.py: `llama_server_bin()`).
  static File get llamaServerBin => File('${home.path}/bin/llama-server');

  /// Run records for detached engines launched by `grid join`, namespaced per
  /// grid: `~/.grid/run/engines/<grid_id>/<engine_id>.{json,log}`. The app reads
  /// these to detect an engine that outlived an app restart (its `grid join`
  /// process keeps serving via the relay until `grid leave`).
  static Directory get runEnginesDir => Directory('${home.path}/run/engines');

  static Directory engineRunDir(String gridId) =>
      Directory('${runEnginesDir.path}/$gridId');

  static File engineRunFile(String gridId, String engineId) =>
      File('${engineRunDir(gridId).path}/$engineId.json');

  static File engineRunLogFile(String gridId, String engineId) =>
      File('${engineRunDir(gridId).path}/$engineId.log');
}
