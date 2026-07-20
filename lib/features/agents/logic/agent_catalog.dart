/// The agents the app knows about — the ones that can be put in charge of a
/// chat, and the ones that are coming.
///
/// Two can run today — Hermes and Codex — each installed through the `grid` CLI
/// (`grid agent install <id>`) and able to answer chats on this computer. The
/// rest are listed so the screen says what it will support instead of pretending
/// the list is finished, but they carry no controls: a button that can't do
/// anything is worse than none.
enum AgentTool {
  hermes(
    id: 'hermes',
    name: 'Hermes',
    tagline: 'Runs locally. Uses your model and tools.',
    runnable: true,
    iconAsset: 'assets/agents/hermes_icon.webp',
  ),
  codex(
    id: 'codex',
    name: 'Codex',
    tagline: "OpenAI's coding agent.",
    runnable: true,
    iconAsset: 'assets/agents/codex_icon.png',
  ),
  openclaw(
    id: 'openclaw',
    name: 'OpenClaw',
    tagline: 'An open-source agent.',
    runnable: false,
    iconAsset: 'assets/agents/openclaw_icon.png',
  );

  const AgentTool({
    required this.id,
    required this.name,
    required this.tagline,
    required this.runnable,
    required this.iconAsset,
  });

  /// What `grid agent install` calls it.
  final String id;

  final String name;

  /// One line: what it is, in the user's terms — and one line is the budget. The
  /// screen's own subtitle already says an agent runs on this computer with your
  /// model and tools, so a tagline that repeats it says nothing twice and wraps
  /// the row to two lines, leaving the list unevenly ranked for no reason. Say
  /// only what sets this agent apart from the others.
  final String tagline;

  /// Whether the app can actually install and run it today. False means the
  /// screen shows it as planned — no install button, no toggle.
  final bool runnable;

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

/// The agent that answers chats today. Named rather than assumed, so the day a
/// second one becomes runnable the places that assume "the agent" are findable.
const AgentTool kChatAgent = AgentTool.hermes;
