import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infrastructure/cli/agent_installer.dart';
import '../playground/logic/chat_sender.dart';

/// Everything the app needs to run and manage one agent backend — the app-side
/// half of the `AgentGateway` contract (autonomous-os/runtimes).
///
/// One `const` instance per agent, held by `kAgents`. Adding an agent is adding
/// a subclass, listing it in the registry, and declaring its [iconAsset] in
/// `pubspec.yaml` — nothing else: every `switch` the app used to grow per agent
/// now dispatches through these members instead.
///
/// `base` so the ACP-repair default ([finishInstall]) lives here and Codex
/// inherits the no-op. Equality is **by [id]** so a definition works as a `Set`
/// member and `def == active` reads true across the `const` singletons the
/// registry vends — but the provider families are keyed by the [id] *string*,
/// not by the object (see `agent_status.dart`).
abstract base class AgentDefinition {
  const AgentDefinition();

  /// What `grid agent install` takes, what `ChatPrefs.chatAgent` stores, and the
  /// key every agent-scoped provider family is keyed by. Stable, lowercase.
  String get id;

  /// The agent's name, in the user's terms.
  String get name;

  /// One line: what sets this agent apart from the others. One line is the
  /// budget — the Agents screen's own subtitle already says an agent runs on
  /// this computer with your model and tools.
  String get tagline;

  /// The agent's own mark, bundled with the app. Declared in `pubspec.yaml` or
  /// it throws at **runtime**, not compile time — which is why the registry test
  /// loads every one of these.
  String get iconAsset;

  /// Reachable only over the Responses API. The one capability the grid-fit
  /// check needs (see `agentRunsOnGrid`): Codex ≥ 0.141 rejects `wire_api =
  /// "chat"`, so it has nothing to say to a chat-completions-only grid.
  bool get needsResponses;

  /// Hidden from a shipped release, shown only in developer builds — for an
  /// agent whose integration isn't finished enough to put in front of a user
  /// yet (e.g. a transport that still needs verifying against a live binary).
  /// The registry drops these from `buildAgents` outside developer mode, so a
  /// user never meets an agent that can't answer. Defaults to false.
  bool get devOnly => false;

  /// How the app installs this agent — the recipe it runs itself, without the
  /// `grid` CLI (a pinned uv tool, a GitHub release binary, or a package-manager
  /// command). The [AgentInstaller] executes it; adding an agent means declaring
  /// one here, not editing a CLI whitelist.
  AgentInstallSpec get installSpec;

  /// Whether this agent is installed on this computer right now — a **reactive**
  /// read, so an install that invalidates the probe (see [reprobe]) refreshes
  /// every watcher.
  bool installed(Ref ref);

  /// The installed build, or null when it isn't installed (or won't say).
  Future<String?> version(Ref ref);

  /// Re-read [installed]/[version] after an install or removal — the probes
  /// cache for the app's lifetime, so anything that changes what's on disk has
  /// to say so here.
  void reprobe(Ref ref);

  /// The [ChatSender] that routes a turn to this agent. It points the agent's
  /// own on-disk config at the grid before running, exactly as before.
  ChatSender sender(Ref ref);

  /// A one-off repair the installer runs right after `grid agent install`.
  /// Returns null on success / nothing-to-do, else the user-facing line. Only
  /// Hermes (finishing its ACP support) overrides this; every other agent
  /// inherits the no-op.
  Future<String?> finishInstall(Ref ref) async => null;

  @override
  bool operator ==(Object other) => other is AgentDefinition && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
