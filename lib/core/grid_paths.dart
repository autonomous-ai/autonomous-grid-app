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

  /// The agent-neutral connector token store (`~/.grid/connectors`). Same idea
  /// as [skillsDir]: a connector linked once must work for every agent, so the
  /// token lands here and each adapter projects it into its own agent's format.
  /// Unlike skills a projection can't be a symlink — agents disagree about the
  /// file format — so it's a transforming copy, re-done on every change.
  static Directory get connectorsDir => Directory('${home.path}/connectors');

  static Directory get outputsDir => Directory('${home.path}/outputs');

  /// Saved Chat conversations, one JSON file per conversation
  /// (`~/.grid/app/chats/<id>.json`). App-owned — the CLI never reads or writes
  /// here; it lives under `app/` to stay clearly namespaced away from CLI state.
  static Directory get chatsDir => Directory('${home.path}/app/chats');

  static File chatFile(String id) => File('${chatsDir.path}/$id.json');

  /// Copies of the app-owned files taken right before a cloud snapshot is
  /// merged in (`~/.grid/app/backups/<stamp>.zip`).
  ///
  /// A download only ever adds and replaces, never deletes — but "replaced by a
  /// copy from another machine" is still a change nobody asked to be permanent,
  /// and this is the way back from it. Only the newest few are kept.
  static Directory get appBackupsDir => Directory('${home.path}/app/backups');

  /// Which cloud snapshot this machine last uploaded or downloaded
  /// (`~/.grid/app/sync_state.json`). Read to warn that the cloud has moved on
  /// since — the one thing standing between a stale push and a snapshot that
  /// silently drops another machine's chats.
  static File get syncStateFile => File('${home.path}/app/sync_state.json');

  /// Media that arrived with a downloaded snapshot
  /// (`~/.grid/outputs/synced/<id>.<ext>`).
  ///
  /// Under `outputs/` because that is what it is — Grid's own output, just
  /// made on the user's other machine — and in its own folder so a sync never
  /// collides with a file this machine generated.
  static Directory get syncedMediaDir => Directory('${outputsDir.path}/synced');

  /// Services an agent started through the `grid-serve` skill: one `<name>.log`
  /// and one `<name>.json` record each. Written by the skill's own script (which
  /// mirrors this path), and named here so the skill card can point the agent —
  /// and later a UI — at one folder rather than a re-typed literal.
  static Directory get servicesDir => Directory('${home.path}/app/services');

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
  /// What each finished code task actually did, one file per task
  /// (`~/.grid/app/task_steps/<id>.json`). App-owned: the relay's task row
  /// carries the agent's closing words and nothing of the run behind them, so
  /// without this a task read tomorrow is a summary with no history (issue #30).
  static Directory get taskStepsDir => Directory('${home.path}/app/task_steps');

  static File get projectTasksFile =>
      File('${home.path}/app/project_tasks.json');

  /// Working checkouts of the shared code projects, one folder each
  /// (`~/.grid/app/code/<project>`). The app keeps them here rather than asking
  /// the user where to put them, and refreshes each after one of their tasks
  /// ships — so "the code on this computer" is a place, not a chore. Written by
  /// `grid project clone`, which owns the folder and is the only thing that may
  /// re-clone into it.
  static Directory get codeDir => Directory('${home.path}/app/code');

  /// Where the working checkout of the project in [folder] lives — a folder name
  /// built by `cloneFolderName`, not a raw project name.
  static Directory projectCodeDir(String folder) =>
      Directory('${codeDir.path}/$folder');

  /// How much context each model turned out to have (`{"<model id>": 96000}`),
  /// learned from the engines themselves. App-owned; the CLI never touches it.
  static File get modelContextFile =>
      File('${home.path}/app/model_context.json');

  /// What each project's last few turns came to — the headlines the Grid Panel
  /// draws, kept so the voice router can read what a project is *working on*
  /// rather than only what it is called.
  ///
  /// A file rather than a field because the question it answers is asked from a
  /// cold start: someone speaks at the panel the minute the app comes up, and a
  /// router with no history behind it has nothing to route on but names.
  /// App-owned; the CLI never touches it.
  static File get panelRecapsFile => File('${home.path}/app/panel_recaps.json');

  /// The first-run onboarding choice (run a model locally, use a cloud provider,
  /// or set up later) — remembered so a user who already picked a path isn't
  /// asked again on every launch, including the paths that install nothing.
  /// App-owned; the CLI never touches it.
  static File get onboardingFile => File('${home.path}/app/onboarding.json');

  /// Whether the one-time welcome screen has already been shown
  /// (`~/.grid/app/welcome.json`). Its own file rather than a field on
  /// [onboardingFile]: that one records a *choice the user made* and is read to
  /// decide where they land, while this only records that a screen was seen.
  /// App-owned; the CLI never touches it.
  static File get welcomeFile => File('${home.path}/app/welcome.json');

  /// The analytics device id, the current visit id, and the user's own
  /// `"enabled": false` switch (`~/.grid/app/analytics.json`).
  ///
  /// App-owned; the CLI never touches it. Its own file rather than a field on
  /// [chatPrefsFile] because it is the one place a person can turn tracking
  /// off, and that answer must not be reachable by anything that rewrites
  /// preferences.
  static File get analyticsFile => File('${home.path}/app/analytics.json');

  /// Which scheduled-task results have already been put into Chat, so a finished
  /// run is delivered once and not again on every launch. App-owned.
  static File get taskDeliveryFile =>
      File('${home.path}/app/task_delivery.json');

  /// The scheduled tasks whose latest result the user hasn't opened yet (a plain
  /// list of job ids) — what the sidebar and the Scheduled list badge, so an
  /// overnight run isn't something to remember to go look for. App-owned.
  static File get taskUnreadFile => File('${home.path}/app/task_unread.json');

  /// The opening line of each scheduled task's newest result, so the Scheduled
  /// list can say what arrived rather than only that something did. App-owned.
  static File get taskInboxFile => File('${home.path}/app/task_inbox.json');

  /// Whether this computer claims the grid's *distributed* coding tasks, and
  /// how many at once. Nothing to do with the scheduled tasks above: claiming
  /// one runs a coding agent against somebody else's repository here, paid for
  /// out of this operator's own Claude subscription — so it is off until they
  /// say otherwise, and the answer has to survive a restart. App-owned.
  static File get taskServingFile => File('${home.path}/app/task_serving.json');

  /// The model this computer starts serving the moment the app opens, if the
  /// user asked for that. Off unless they ticked the box, and it names the model
  /// and grid explicitly rather than "whatever is first" — a launch that shares
  /// a different model than the one chosen is worse than not starting at all.
  /// App-owned.
  static File get autoServeFile => File('${home.path}/app/auto_serve.json');

  /// Working directory for the agent that answers chat. It runs read-only here
  /// so its file tools have a stable, app-owned root instead of pointing at the
  /// user's home. App-owned — the CLI never touches it.
  static Directory get agentWorkspaceDir =>
      Directory('${home.path}/app/agent-workspace');

  /// Feedback that couldn't be sent (`~/.grid/feedback`), one JSON file per
  /// attempt. App-owned — the CLI never touches it.
  ///
  /// A send that fails would otherwise discard something the user sat down and
  /// wrote; this keeps the exact payload so they can retry, or send us the file.
  static Directory get feedbackDir => Directory('${home.path}/feedback');

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
  /// Where Grid keeps the tools it owns — the built-in engine (installed by the
  /// CLI) and the agents (installed by the app). Everything lands here, so
  /// nothing depends on Homebrew or on the user's `PATH`.
  static Directory get binDir => Directory('${home.path}/bin');

  /// Where `uv` keeps the agent tools it installs for Grid — one venv per tool
  /// (mirrors the CLI's `paths.tools_dir()`). Under `~/.grid` so Grid owns what
  /// Grid installed and a directory removal uninstalls it.
  static Directory get toolsDir => Directory('${home.path}/tools');

  /// Where the app unpacks its own Git when this computer has none.
  ///
  /// A whole tree rather than a single binary in [binDir]: Git needs its
  /// `libexec/git-core` helpers beside it (without them `git clone` over HTTPS
  /// fails with `'remote-https' is not a git command`), so it is unpacked whole
  /// and reached through [HostEnvironment.gitEnvironment].
  static Directory get gitDir => Directory('${toolsDir.path}/git');

  /// Where `uv` downloads the private CPython those tools run on (mirrors the
  /// CLI's `paths.python_dir()`). Under `~/.grid` for the same reason.
  static Directory get pythonDir => Directory('${home.path}/python');

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
