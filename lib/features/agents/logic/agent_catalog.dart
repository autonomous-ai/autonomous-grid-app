/// The agents the app can put in charge of a chat.
///
/// Every entry here runs today: installed through the `grid` CLI (`grid agent
/// install &lt;id&gt;`) and able to answer chats on this computer. An agent the app
/// can't install doesn't belong on the list — a row the user can only look at
/// takes up the same space as a working one and answers nothing.
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
  );

  const AgentTool({
    required this.id,
    required this.name,
    required this.tagline,
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
