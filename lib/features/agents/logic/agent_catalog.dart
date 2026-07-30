/// The agents the app can put in charge of a chat.
///
/// Every entry here runs today: the app can get it onto this computer, and it
/// can answer chats here. An agent the app can't install doesn't belong on the
/// list — a row the user can only look at takes up the same space as a working
/// one and answers nothing.
///
/// *How* it gets installed differs, and that difference lives in
/// `AgentInstallController`, not here: Hermes and Codex come through the `grid`
/// CLI (`grid agent install <id>`), Claude Code through its vendor's own
/// installer, because the CLI has no recipe for it.
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

  /// The agent's own slug — what `grid agent install` calls it, and the value
  /// [ChatPrefs.chatAgent] remembers.
  final String id;

  final String name;

  /// One line: what it is, in the user's terms — and one line is the budget. The
  /// screen's own subtitle already says an agent runs on this computer with your
  /// model and tools, so a tagline that repeats it says nothing twice and wraps
  /// the row to two lines, leaving the list unevenly ranked for no reason. Say
  /// only what sets this agent apart from the others.
  final String tagline;

  /// Which installer puts this agent on the machine: `grid agent install <id>`
  /// for the ones the CLI packages (Hermes, Codex), the vendor's own script for
  /// Claude Code, which the CLI has no recipe for. `AgentInstaller` reads this to
  /// pick the route; every surface then installs any agent the same way.
  ///
  /// It is a *route* flag, not a permission one: Claude Code auto-installs in the
  /// background at startup like the others (its script needs no admin rights —
  /// `~/.local/bin`, no sudo). What it still gates is the **CLI-argv setup plan**
  /// ([buildSetupPlan]): those steps are literal `grid …` argv, so an agent with
  /// no CLI recipe can't be one and rides the background installer instead.
  bool get packagedByCli => this != AgentTool.claude;

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
