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
    strengths:
        'General questions, research and web search, writing, running local '
        'tools and MCP connectors, day-to-day chat. The all-rounder for '
        'anything that is not specifically writing code.',
  ),
  codex(
    id: 'codex',
    name: 'Codex',
    tagline: "OpenAI's coding agent.",
    iconAsset: 'assets/agents/codex_icon.png',
    strengths:
        'Writing, editing and debugging code; running commands and tests in a '
        'repository; refactors and multi-file changes. A focused coding agent.',
  ),
  claude(
    id: 'claude',
    name: 'Claude Code',
    tagline: "Anthropic's coding agent.",
    iconAsset: 'assets/agents/claude_icon.png',
    strengths:
        'Careful reasoning over a codebase, larger refactors, explaining and '
        'reviewing code, and long multi-step engineering tasks. Strong at '
        'planning a change before making it.',
  );

  const AgentTool({
    required this.id,
    required this.name,
    required this.tagline,
    required this.iconAsset,
    required this.strengths,
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

  /// What this agent is *best at*, in prose — the material the Auto agent's
  /// router shows a model so it can pick the right one for a question. Longer
  /// and more specific than [tagline], which is chrome; this is a description a
  /// classifier reasons over, so it names the kinds of work each agent wins on.
  final String strengths;

  /// Whether a conversation with this agent survives the app being quit.
  ///
  /// True for the two that run one process per turn and keep the conversation
  /// in a file of their own, resumed by id: `claude --resume <id>` and Codex's
  /// own thread id. Their sessions outlive both the process that
  /// made them and this app, which is what lets a chat pick one back up — and
  /// what lets a session started in those tools be imported and carried on
  /// (see `AgentResumePoint`).
  ///
  /// False for Hermes, whose session *is* a live ACP process: when it exits the
  /// session is gone, and an id written down for it would name nothing.
  bool get resumesBySessionId =>
      this == AgentTool.claude || this == AgentTool.codex;

  /// Whether this agent has an **interactive CLI** this app can drive in a
  /// terminal — so a chat with it *can* be shown as that program itself.
  ///
  /// True for Claude Code and Codex, and it is what gives the user back
  /// everything the one-shot text lane cannot offer: the CLI asks for permission
  /// in its own words and takes the answer from the keyboard, a message typed
  /// mid-answer reaches the turn that is running, and the conversation is the
  /// CLI's own rather than a transcript replayed into every prompt. Nothing is
  /// parsed on the way through — a pty carries the bytes and an emulator draws
  /// them.
  ///
  /// False for Hermes, which has no interactive CLI this app drives: it speaks
  /// ACP, and its chat is built out of those events.
  ///
  /// **A capability, not the choice.** Whether a given chat is actually drawn
  /// that way is `AgentChatSurface`, which the user sets once on Appearance and
  /// a chat then fixes when it starts — see `agentChatSurface`. This is only
  /// the half that says the choice exists at all.
  ///
  /// It is *not* the whole story of how a chat reaches these two either. A turn
  /// the app sends by itself — a goal's next step, a loop's beat, a scheduled
  /// task — has no keyboard behind it and still goes out through the one-shot
  /// lane (`claude -p` / `codex exec`).
  bool get hasInteractiveCli =>
      this == AgentTool.claude || this == AgentTool.codex;

  /// Whether this agent can look at a picture by **opening the file itself**.
  ///
  /// True for Claude Code and Codex. Neither takes an image on the wire the way
  /// Hermes does — what they take is a path and a tool that opens it: Claude
  /// Code's `Read` hands an image file to the model as an image block (which is
  /// why `claudeMediaTokens` exists at all — it counts the screenshots that
  /// arrive this way), and Codex's `view_image` attaches a local file to the
  /// thread. So a picture reaches them as a line saying where it is, written by
  /// [withAttachedMedia], and the app saves every attachment to disk before the
  /// turn goes out ([buildUserTurn]) — the path is real on both lanes.
  ///
  /// False for Hermes, which is handed the bytes themselves over ACP
  /// ([acpImages]) and has its own auxiliary vision model behind that.
  ///
  /// **It says nothing about the model.** The agent only carries the picture to
  /// whatever is answering, so a model that cannot see is still a model that
  /// cannot see — see [agentReadsImagesForChat], which asks both questions.
  bool get opensImageFiles =>
      this == AgentTool.claude || this == AgentTool.codex;

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

/// The agent stored under [id], or null when nothing (or nothing this build
/// still ships) is named.
///
/// Ids are read back from disk — a project's saved choice, the app's prefs — so
/// an id from a build that carried an agent this one has dropped has to resolve
/// to "no choice" rather than throw.
AgentTool? agentToolById(String? id) {
  for (final tool in AgentTool.values) {
    if (tool.id == id) return tool;
  }
  return null;
}
