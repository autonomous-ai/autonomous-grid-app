/// How Grid's own browser tools are named to an agent, and what to say to the
/// user when one of them asks to act.
///
/// Claude Code stops before every tool it hasn't been told it may use and asks
/// this app (`--permission-prompt-tool`). Left alone, a browser call arrives at
/// that card as `mcp__grid__browser_click` over `ref: e12` — which is not a
/// question a person can answer, and there would be five of them in the time it
/// takes to run one search.
///
/// So: the tools that only *look* are answered by the transport, and the ones
/// that *act* get a sentence.
library;

/// The prefix Claude Code puts on a tool from an MCP server, for the server
/// this app registers as `grid` (see `agent_grid_setup.dart`).
const String kGridMcpToolPrefix = 'mcp__grid__';

/// The bare tool name inside [tool], or '' when it isn't one of Grid's.
String gridMcpToolName(String tool) => tool.startsWith(kGridMcpToolPrefix)
    ? tool.substring(kGridMcpToolPrefix.length)
    : '';

/// Whether [tool] only reads the page.
///
/// These are answered yes without asking anyone, and that is the same rule
/// `AgentApprovalMode` already states for the rest of the app: "Reading,
/// searching and looking things up online are always allowed and never
/// interrupt anyone." A snapshot changes nothing, and a flow as ordinary as
/// "search for this" takes three of them.
///
/// Deliberately a **list of what is free**, not a list of what to ask about: a
/// browser tool added later is one nobody has thought about yet, and the safe
/// side of that mistake is asking.
bool gridBrowserToolReadsOnly(String tool) => const {
  'browser_snapshot',
  'browser_read',
  'browser_screenshot',
}.contains(gridMcpToolName(tool));

/// What to put on the permission card for [tool], or null when [tool] is not
/// one of Grid's browser tools.
///
/// The summary says what will happen to the browser tab in the user's own
/// words; the detail carries the part they need to judge it — the address, the
/// text being typed. A ref is left out of both: `e12` means nothing to the
/// person being asked, and a card that shows it is a card that reads as noise.
({String summary, String detail})? gridBrowserToolCard(
  String tool,
  Map<Object?, Object?> input,
) {
  final url = '${input['url'] ?? ''}'.trim();
  final text = '${input['text'] ?? ''}'.trim();
  return switch (gridMcpToolName(tool)) {
    'browser_navigate' => (summary: 'Open a page in the browser', detail: url),
    'browser_click' => (
      summary: 'Click something on the page',
      // Nothing useful to add: what it would click is a ref, and the page is
      // on screen beside the chat for anyone who wants to look.
      detail: '',
    ),
    'browser_type' => (
      summary: input['submit'] == true
          ? 'Type on the page and press Enter'
          : 'Type on the page',
      detail: text,
    ),
    'browser_back' => (summary: 'Go back a page in the browser', detail: ''),
    _ => null,
  };
}
