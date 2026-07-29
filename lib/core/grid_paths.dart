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

  /// The agent-neutral skills store (`~/.grid/skills`). Skills the user writes
  /// in the app land here — outside any one agent's home — and each agent is
  /// pointed at it by its adapter (Hermes via `skills.external_dirs`; Codex
  /// later by sync). Skills that already live in an agent's own folder stay
  /// there; this is where *new* ones go so no agent owns the user's work.
  static Directory get skillsDir => Directory('${home.path}/skills');

  static Directory get outputsDir => Directory('${home.path}/outputs');

  /// Saved Chat conversations, one JSON file per conversation
  /// (`~/.grid/app/chats/<id>.json`). App-owned — the CLI never reads or writes
  /// here; it lives under `app/` to stay clearly namespaced away from CLI state.
  static Directory get chatsDir => Directory('${home.path}/app/chats');

  static File chatFile(String id) => File('${chatsDir.path}/$id.json');

  /// The Chat tab's remembered selections (last grid, last model), so reopening
  /// the app restores them. App-owned — the CLI never touches it.
  static File get chatPrefsFile => File('${home.path}/app/chat_prefs.json');

  /// The folders the user added as projects — the ones a chat can be opened
  /// "inside", so the assistant may read them. App-owned.
  static File get projectsFile => File('${home.path}/app/projects.json');

  /// Which scheduled task belongs to which project (`{"<jobId>": "<projectId>"}`),
  /// so a project's rail can show only its own tasks. The scheduler is Hermes's
  /// (jobs live in `~/.hermes/cron`); this app-owned map is the only record of
  /// the project a task was created for, since Hermes doesn't know about projects.
  static File get projectTasksFile =>
      File('${home.path}/app/project_tasks.json');

  /// The user's saved prompts — reusable messages they insert into the composer
  /// with `/`. App-owned; the CLI never touches it.
  static File get promptsFile => File('${home.path}/app/prompts.json');

  /// The first-run onboarding choice (run a model locally, use a cloud provider,
  /// or set up later) — remembered so a user who already picked a path isn't
  /// asked again on every launch, including the paths that install nothing.
  /// App-owned; the CLI never touches it.
  static File get onboardingFile => File('${home.path}/app/onboarding.json');

  /// Which scheduled-task results have already been put into Chat, so a finished
  /// run is delivered once and not again on every launch. App-owned.
  static File get taskDeliveryFile =>
      File('${home.path}/app/task_delivery.json');

  /// The scheduled tasks whose latest result the user hasn't opened yet (a plain
  /// list of job ids) — what the sidebar and the Scheduled list badge, so an
  /// overnight run isn't something to remember to go look for. App-owned.
  static File get taskUnreadFile =>
      File('${home.path}/app/task_unread.json');

  /// Working directory for the agent that answers chat. It runs read-only here
  /// so its file tools have a stable, app-owned root instead of pointing at the
  /// user's home. App-owned — the CLI never touches it.
  static Directory get agentWorkspaceDir =>
      Directory('${home.path}/app/agent-workspace');

  /// The CLI's own log directory (`~/.grid/logs`, e.g. `llama_llm_*.log`). The
  /// app drops its own diagnostic logs here too so everything a user might send
  /// us to debug lives in one place. Each app log rotates per calendar day into
  /// `<base>-YYYYMMDD.log` (see [DailyLogFile]) so no single file grows without
  /// bound.
  static Directory get logsDir => Directory('${home.path}/logs');

  /// Filename stem for the app's narrative timeline (`app-YYYYMMDD.log`):
  /// lifecycle milestones, every CLI/HTTP call as a one-liner, and every uncaught
  /// error with its stack trace. The first file to read to understand what the
  /// app was doing and where it broke; [cliLogBase] holds the deeper per-command
  /// CLI output.
  static const String appLogBase = 'app';

  /// Filename stem for the durable transcript of every `grid` CLI call the app
  /// makes (`app_cli-YYYYMMDD.log`): command, streamed output, outcome. The
  /// in-app Debug tab is a capped in-memory ring buffer gone once the app closes;
  /// this file survives so a user can send it to us to debug a failed command.
  static const String cliLogBase = 'app_cli';

  /// Filename stem for the background node-setup / auto-install transcript
  /// (`app_node_setup-YYYYMMDD.log`), written by the app itself (not the CLI).
  /// The in-app log is in-memory only and gone once the app closes; this file
  /// survives a failed silent install so it can be debugged after the fact.
  static const String nodeSetupLogBase = 'app_node_setup';

  /// Filename stem for the transcript of every HTTP request the app makes
  /// (`app_https-YYYYMMDD.log`): relay chat/media and the managed-grid API. Kept
  /// apart from [appLogBase] so a user debugging a network problem can send just
  /// the HTTP trace. Each line is written the moment the request is issued.
  static const String httpLogBase = 'app_https';

  /// Where `grid llama.cpp install` links the engine (provider_runtime
  /// paths.py: `llama_server_bin()`).
  /// Where the CLI installs the tools it owns — the built-in engine, and the
  /// chat agent (`grid agent install hermes`). Grid installs them itself, so
  /// nothing here depends on Homebrew or on the user's `PATH`.
  static Directory get binDir => Directory('${home.path}/bin');

  static File get llamaServerBin => File('${binDir.path}/llama-server');

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
