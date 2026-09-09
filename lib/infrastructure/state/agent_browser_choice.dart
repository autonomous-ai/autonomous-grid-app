/// Which browser the assistant reaches for, when it needs one.
///
/// One question with one answer, in one place. It used to be two unrelated
/// controls that never named each other: a switch on the agent's card ("let it
/// open a browser of its own") and, invisible beside it, a lane that drove the
/// user's *real* Chrome whenever the Claude extension happened to be installed
/// — no switch at all, on the reasoning that installing the extension was
/// consent enough. It isn't the same consent: one opens a window signed in to
/// nothing, the other acts as the user in every account they are signed in to.
///
/// Stored as [id] rather than by [name] so renaming a constant can't silently
/// reset everyone's answer.
enum AgentBrowserChoice {
  /// No browser. The assistant answers from what it knows and what the grid's
  /// `web_search` / `web_fetch` can reach.
  none('none', 'Off'),

  /// Grid's own Browser tab, in the panel beside the conversation.
  ///
  /// The only one that works for **every** assistant — it goes through Grid's
  /// MCP server rather than through any one CLI's browser support — and the
  /// only one the user watches happen.
  gridTab('grid_tab', 'Grid’s Browser tab'),

  /// A Chrome of the app's own, signed in to nothing.
  cleanWindow('clean_window', 'A clean browser on this computer'),

  /// The Chrome the user already has open, with every account in it.
  yourBrowser('your_browser', 'The browser you already use');

  const AgentBrowserChoice(this.id, this.label);

  /// What the settings file stores.
  final String id;

  /// The control's own words.
  final String label;

  /// The choice [id] names, or [none] for an id this build doesn't know.
  static AgentBrowserChoice byId(String id) {
    for (final choice in values) {
      if (choice.id == id) return choice;
    }
    return none;
  }

  /// What a settings file written before this setting existed meant.
  ///
  /// The old switch was `agentBrowser`, and its own words were "let it open a
  /// browser **of its own**" — so a user who ticked it asked for
  /// [cleanWindow], and that is what they keep.
  ///
  /// A user who left it alone gets [none], and that is a **deliberate
  /// narrowing**: the extension lane used to run for them without ever being
  /// offered, driving the Chrome they are signed into. Turning that into
  /// something they pick is the point of this enum.
  static AgentBrowserChoice fromLegacySwitch(bool agentBrowser) =>
      agentBrowser ? cleanWindow : none;
}
