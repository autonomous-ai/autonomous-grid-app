import '../../../infrastructure/cli/agent_release_pins.dart';
import '../../../infrastructure/cli/agent_spec_installer.dart';
import '../../../infrastructure/cli/hermes_acp_setup.dart';

/// The agents the app can put in charge of a chat.
///
/// Every entry here runs today: the app can get it onto this computer, and it
/// can answer chats here. An agent the app can't install doesn't belong on the
/// list — a row the user can only look at takes up the same space as a working
/// one and answers nothing.
///
/// *How* it gets installed is [installSpec]: a recipe the app runs itself, so
/// adding an agent is a change here and nowhere else. Claude Code is the one
/// exception — it ships its own installer, which knows things about its release
/// channel that a pinned URL here would only get wrong.
enum AgentTool {
  hermes(
    id: 'hermes',
    name: 'Hermes',
    tagline: 'Runs locally. Uses your model and tools.',
    iconAsset: 'assets/agents/hermes_icon.webp',
  ),
  codex(
    id: 'codex',
    name: 'Codex',
    tagline: "OpenAI's coding agent.",
    iconAsset: 'assets/agents/codex_icon.png',
  ),
  claude(
    id: 'claude',
    name: 'Claude Code',
    tagline: "Anthropic's coding agent.",
    iconAsset: 'assets/agents/claude_icon.png',
  );

  const AgentTool({
    required this.id,
    required this.name,
    required this.tagline,
    required this.iconAsset,
  });

  /// The agent's own slug — how it is named on disk and in the log, and the
  /// value [ChatPrefs.chatAgent] remembers.
  final String id;

  final String name;

  /// One line: what it is, in the user's terms — and one line is the budget. The
  /// screen's own subtitle already says an agent runs on this computer with your
  /// model and tools, so a tagline that repeats it says nothing twice and wraps
  /// the row to two lines, leaving the list unevenly ranked for no reason. Say
  /// only what sets this agent apart from the others.
  final String tagline;

  /// The recipe the app runs to put this agent on the machine, or null for an
  /// agent that ships its own installer (Claude Code — see
  /// `ClaudeInstaller`). `AgentInstaller` reads this to pick the route; every
  /// surface then installs any agent the same way.
  ///
  /// Both recipes land inside `~/.grid`, need no Homebrew and no admin rights,
  /// and verify what they download against a pinned hash before running it.
  /// Hermes's requirement is [kHermesAcpRequirement] — the same string the
  /// self-repair uses, so an install and a repair can never ask for different
  /// extras and leave the agent half-equipped.
  AgentInstallSpec? get installSpec => switch (this) {
    AgentTool.hermes => const UvToolInstall(
      package: kHermesAcpRequirement,
      python: kHermesPython,
    ),
    AgentTool.codex => const GithubReleaseBinary(
      executable: 'codex',
      buildFor: codexBuildFor,
      linuxMusl: true,
    ),
    AgentTool.claude => null,
  };

  /// The agent's own mark, bundled with the app (declared in `pubspec.yaml`).
  ///
  /// These are each project's real logo, so they arrive with their own colour and
  /// their own backdrop — which is why a row draws the image itself rather than
  /// tinting a glyph the way the plugin list does. Adding an agent means adding
  /// its file to `assets/agents/` *and* to `pubspec.yaml`; a path that isn't
  /// declared there throws at runtime, not at compile time, so
  /// `agent_catalog_test.dart` loads every one of these to catch it in CI.
  final String iconAsset;
}

/// The agent that answers chats before the user picks one. Named rather than
/// assumed, so the places that assume "the agent" stay findable.
const AgentTool kChatAgent = AgentTool.hermes;
