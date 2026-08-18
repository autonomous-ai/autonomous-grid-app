/// What kind of step the agent is running — a shell command, a look-up on the
/// web, the model's own reasoning, or any other tool. The kind picks the icon
/// in the activity feed.
enum AgentActivityKind { command, web, tool, thinking }

/// Lifecycle of one agent step, driving its live status indicator.
enum AgentActivityStatus {
  running,
  done,
  failed,

  /// The turn ended without this step ever reporting how it went.
  ///
  /// It exists because the alternatives both lie. A tick claims the step
  /// succeeded; a red mark claims it failed — and a saved transcript full of red
  /// marks says an agent's work went wrong when all that is known is that the
  /// app stopped hearing about it. Reached two ways: the user pressed Stop
  /// mid-tool, and a transport that simply doesn't always send a closing update
  /// (Hermes over ACP).
  unknown,
}

/// One agent step in the live activity feed — a shell command or a tool call the
/// agent ran while answering. Keyed by [id] so a `started` event and its later
/// `completed` event update the same row rather than duplicating it.
///
/// Lives in the infrastructure layer because the agent transport (Hermes over
/// ACP) emits these; the chat surfaces them in its "agent is working" bubble so
/// the user can see *what* the agent is doing, not just that it's busy.
class AgentActivity {
  const AgentActivity({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    this.tool,
    this.request,
    this.result,
    this.parent,
    this.startedAt,
  });

  final String id;
  final AgentActivityKind kind;

  /// Short human label — the shell command, or the tool name.
  final String label;
  final AgentActivityStatus status;

  /// The tool's own name, as the agent calls it (`Bash`, `Read`, `terminal`,
  /// `command_execution`), or null on a row that isn't a tool call.
  ///
  /// Kept beside [label] rather than parsed back out of it: the label is written
  /// for a person and each agent words it differently, so a row that wants to
  /// say "Read conventions.md" has no reliable way to recover which tool ran.
  final String? tool;

  /// What the agent asked the tool to do, as text the user can read — the
  /// command line, or the call's arguments as JSON. Null when the transport
  /// doesn't carry it (see the per-agent notes on each parser).
  ///
  /// Capped at [kToolPayloadLimit]: this is shown in a fold and saved with the
  /// conversation, and a step that read a 200KB file must not put 200KB into a
  /// chat file that is rewritten on every turn.
  final String? request;

  /// What came back, same terms as [request]. Null while the step is still
  /// running, and on a transport that reports no result.
  final String? result;

  /// The tool call this step ran *inside*, or null when the agent itself ran it.
  ///
  /// Claude Code's `Agent` tool (`Task` in older builds) starts a sub-agent,
  /// and that sub-agent's whole
  /// working life — its thoughts, its file reads, its commands — comes back in
  /// the same stream as the main agent's, tagged with the id of the `Task` call
  /// that started it. So a step is not always the agent's own: it can belong to
  /// something the agent delegated, and the chat has to be able to tell, or a
  /// sub-agent reading thirty files reads as the agent doing it.
  final String? parent;

  /// When this step began, or null on a step nobody has stamped.
  ///
  /// Stamped once, by [AgentRuns.upsertStep], and never moved afterwards: the
  /// two halves of a step arrive as separate events, and re-stamping on the
  /// closing one would say the step started when it finished. Not persisted —
  /// a saved transcript's steps are all over, and "how long did that take" is
  /// a question about a turn you are watching.
  final DateTime? startedAt;

  /// Whether this step belongs to a sub-agent rather than to the agent itself.
  bool get isNested => parent != null;

  /// This step stamped as having begun at [when], keeping a stamp it already
  /// carries — a row that is already running did not start again.
  AgentActivity begunAt(DateTime when) => startedAt != null
      ? this
      : AgentActivity(
          id: id,
          kind: kind,
          label: label,
          status: status,
          tool: tool,
          request: request,
          result: result,
          parent: parent,
          startedAt: when,
        );

  /// Whether there is anything to show if the user opens this row.
  bool get hasPayload =>
      (request?.isNotEmpty ?? false) || (result?.isNotEmpty ?? false);

  /// This step with its outcome filled in, keeping what the call itself said.
  ///
  /// The two halves arrive as separate events — the call announces the request,
  /// a later event carries the result — and the feed keys them to one row, so
  /// the second must not overwrite the first with nulls.
  AgentActivity settled({
    required AgentActivityStatus status,
    String? result,
  }) => AgentActivity(
    id: id,
    kind: kind,
    label: label,
    status: status,
    tool: tool,
    request: request,
    result: clipToolPayload(result) ?? this.result,
    parent: parent,
    startedAt: startedAt,
  );
}

/// How much of a tool's request or result is worth keeping.
///
/// It is read in a fold under one step of one turn, and written into
/// `~/.grid/app/chats/<id>.json`, which is rewritten whole on every turn. A
/// single `cat` of a large file would otherwise outweigh the entire
/// conversation around it — and nobody reads the 40th screen of a build log out
/// of a chat bubble anyway.
const int kToolPayloadLimit = 4000;

/// [raw] trimmed and capped at [kToolPayloadLimit], or null when there is
/// nothing to show. The cut says how much was dropped rather than trailing off
/// into an ellipsis: a payload that stops mid-word reads as a bug unless the
/// line under it says it was cut on purpose.
String? clipToolPayload(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return null;
  if (text.length <= kToolPayloadLimit) return text;
  // Never cut between the two halves of a surrogate pair. Dart counts UTF-16
  // code units, and an emoji is two of them — landing between them leaves a lone
  // high surrogate, which is not valid text: it survives `jsonEncode` but comes
  // back as a replacement glyph, and a payload can be anything (a log, a diff, a
  // file full of them).
  final end = _isHighSurrogate(text.codeUnitAt(kToolPayloadLimit - 1))
      ? kToolPayloadLimit - 1
      : kToolPayloadLimit;
  final dropped = text.length - end;
  return '${text.substring(0, end)}\n\n… $dropped more characters';
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// A web page the agent consulted while answering — one citation shown under the
/// reply, so an answer built from the web says where it came from instead of
/// asking the user to take it on faith.
class WebSource {
  const WebSource({required this.title, required this.url});

  /// The page's own title, or its host when the search returned none — the label
  /// the user reads on the chip.
  final String title;

  /// What opens when the chip is clicked.
  final String url;

  /// The bare host ("example.com", the leading `www.` dropped) — a compact
  /// secondary label under the title.
  String get host {
    final parsed = Uri.tryParse(url);
    final host = parsed?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  Map<String, Object?> toJson() => {'title': title, 'url': url};

  static WebSource? fromJson(Map<String, dynamic> json) {
    final url = json['url'];
    if (url is! String || url.isEmpty) return null;
    final title = json['title'];
    return WebSource(
      title: title is String && title.isNotEmpty ? title : url,
      url: url,
    );
  }
}

/// Pulls the citations out of Hermes's `web_search` tool result — the lines it
/// formats as `• Title — https://url`. The `Web results: N` header and the
/// indented description lines are skipped, a bullet with no link isn't a
/// citation and is dropped, and duplicate urls collapse to the first. Order is
/// preserved so the list reads in the agent's own ranking.
List<WebSource> parseWebSearchSources(String content) {
  const bullet = '•';
  const separator = ' — ';
  final sources = <WebSource>[];
  final seen = <String>{};
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (!line.startsWith(bullet)) continue;
    final body = line.substring(bullet.length).trim();
    final cut = body.lastIndexOf(separator);
    final title = cut >= 0 ? body.substring(0, cut).trim() : body;
    final url = cut >= 0 ? body.substring(cut + separator.length).trim() : body;
    if (!url.startsWith('http://') && !url.startsWith('https://')) continue;
    if (!seen.add(url)) continue;
    sources.add(WebSource(title: title.isEmpty ? url : title, url: url));
  }
  return List.unmodifiable(sources);
}

/// Where one step of the agent's to-do plan stands.
enum AgentPlanStatus {
  /// Not started yet.
  pending,

  /// The step the agent is on right now.
  active,

  /// Finished.
  done,
}

/// One step in the agent's live to-do plan — something it intends to do, and how
/// far along it is. Hermes keeps this list through its own `todo` tool and emits
/// the whole thing over ACP as a `plan` update; the chat shows it as a checklist
/// so the user sees the steps and which one the agent is on, not just a spinner.
class AgentPlanEntry {
  const AgentPlanEntry({required this.content, required this.status});

  /// The step, in the agent's own words.
  final String content;

  final AgentPlanStatus status;

  Map<String, Object?> toJson() => {'content': content, 'status': status.name};

  /// Reconstruct a *persisted* entry — its [status] is this enum's own name
  /// (what [toJson] wrote), not the ACP wire vocabulary [parseAgentPlan] reads.
  static AgentPlanEntry? fromJson(Map<String, dynamic> json) {
    final content = cleanPlanContent(json['content']);
    if (content == null) return null;
    return AgentPlanEntry(
      content: content,
      status: _planStatusByName(json['status']),
    );
  }
}

/// A plan step's text once cleaned, or null when it's nothing worth showing.
///
/// Dropped: a blank step, and Hermes's own `todo`-tool placeholders —
/// `(no description)` / `(invalid item)`, which it substitutes when the model's
/// item carried no usable `content`. A weaker model that fills the `todo` tool
/// with the step text under the wrong key leaves a plan that is all placeholders
/// (a wall of "(no description)" the user reads as a bug); by the time the app
/// sees it Hermes has already discarded the real text, so the honest move is to
/// drop the empty rows rather than render them.
String? cleanPlanContent(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  const placeholders = {'(no description)', '(invalid item)'};
  return placeholders.contains(trimmed.toLowerCase()) ? null : trimmed;
}

/// Parses an ACP `plan` update's `entries` into the agent's to-do list. Each
/// entry is `{content, status}` where status is ACP's own
/// `pending`/`in_progress`/`completed`; anything else reads as pending. A blank
/// step, or one Hermes filled with a placeholder ([cleanPlanContent]), is
/// dropped. The list replaces the previous plan wholesale — Hermes sends the full
/// to-do state each time, not a delta.
List<AgentPlanEntry> parseAgentPlan(Object? entries) {
  if (entries is! List) return const [];
  final plan = <AgentPlanEntry>[];
  for (final entry in entries) {
    if (entry is! Map) continue;
    final content = cleanPlanContent(entry['content']);
    if (content == null) continue;
    plan.add(
      AgentPlanEntry(
        content: content,
        status: _planStatusFromAcp(entry['status']),
      ),
    );
  }
  return List.unmodifiable(plan);
}

/// Whether the agent left its to-do plan unfinished — it laid out steps and the
/// turn ended before every one reached [AgentPlanStatus.done].
///
/// An empty plan is *not* unfinished: a turn that never made a plan (a plain
/// answer, or planning mode's text-only outline) has nothing left hanging. The
/// chat uses this to tell an honest "stopped part-way" from a real answer — a
/// turn that announces a plan and then stalls (no steps ticked off, nothing
/// built) must not read as success (§5).
bool agentPlanUnfinished(List<AgentPlanEntry> plan) =>
    plan.isNotEmpty && plan.any((step) => step.status != AgentPlanStatus.done);

/// Whether a turn that has just ended stalled part-way through its own plan: it
/// left steps open *and* a fact about the turn says it never got to them.
///
/// [agentPlanUnfinished] on its own can't say that — a model routinely does the
/// work and never ticks the last box. One turn read a 51-comment thread through
/// the browser, summarized all of it, and left two of three steps open: the plan
/// was the only thing consulted, so a complete answer landed under "the agent
/// planned the work but stopped before finishing it", with an offer to hand the
/// chat to another agent for work already done. Two facts decide it instead:
///
/// - [endedCleanly] — the agent's own runtime reported the turn over by itself
///   (Codex's `turn.completed` or a clean exit, ACP's `end_turn`). A turn cut
///   short — killed, broken stream, token ceiling — with steps still open didn't
///   do them, whatever text landed.
/// - [workedAtAll] — it ran a command, called a tool or changed a file at some
///   point in the turn. Announcing steps and going straight to "let me write it
///   for you" is the stall this check was written for; sixty tool calls and then
///   a long answer is not.
///
/// Deliberately *not* "worked since it last revised the plan": that read the
/// agent's rhythm backwards. A review turn ran 66 commands, ticked five of its
/// six boxes in one closing `update_plan`, then wrote the review — its own
/// book-keeping was the last thing to happen, so every command before it counted
/// for nothing and a finished review was called a stall. The price of the looser
/// fact is a turn that works, plans more, then only promises the rest: that now
/// reads as an answer, which is the cheaper mistake.
///
/// Planning mode is never a stall — there an unfinished plan is the whole point
/// — so the caller passes [planFirst].
bool agentTurnStalled({
  required List<AgentPlanEntry> plan,
  required bool endedCleanly,
  required bool workedAtAll,
  required bool planFirst,
}) =>
    !planFirst && agentPlanUnfinished(plan) && (!endedCleanly || !workedAtAll);

/// Whether the turn stopped because it ran out of room, not because it was done.
///
/// Hermes caps a turn at `agent.max_turns` model round-trips. At the cap it
/// tells the model "You've reached the maximum number of tool-calling iterations
/// allowed" and asks it to summarise — then reports the turn over as a plain
/// `end_turn`, the same word a finished turn gets. So a five-step plan abandoned
/// at step three reached the chat looking exactly like completed work, and the
/// user was left with "why does it keep stopping halfway?" and nothing to read.
///
/// Two facts, because neither is enough alone:
///
/// - [toolCalls] against [budget] — the app counts *tool calls* while Hermes
///   counts *round-trips*, and one round-trip can carry several calls. So a
///   count at or past the budget makes the cap likely, never certain.
/// - [plan] unfinished — the symptom the user is actually looking at. Requiring
///   it is what keeps the looser count above from stamping "ran out of room" on
///   a turn that did the work and simply used a lot of tools.
///
/// The pair is deliberately conservative: it can stay quiet about a capped turn
/// that ticked every box, which costs nothing, rather than tell a user their
/// finished work was cut short.
bool agentSpentToolBudget({
  required int toolCalls,
  required int budget,
  required List<AgentPlanEntry> plan,
}) => budget > 0 && toolCalls >= budget && agentPlanUnfinished(plan);

/// Whether an activity row is the agent *doing* something — running a command,
/// calling a tool, looking something up — rather than thinking about it. The
/// stall check above counts work, and a model's own reasoning isn't work.
bool isAgentWork(AgentActivity activity) =>
    activity.kind != AgentActivityKind.thinking;

/// The evidence behind a stall verdict, for the log.
///
/// The line the user reads names none of it, and a log that only repeats that
/// line diagnoses nothing (§6) — working out why one finished answer was called a
/// stall meant reconstructing the turn from Codex's own session files. These are
/// the three inputs [agentTurnStalled] weighed, so the next report is a read of
/// the log instead.
String describeAgentStall({
  required List<AgentPlanEntry> plan,
  required bool endedCleanly,
  required bool workedAtAll,
}) =>
    'turn stalled mid-plan (ended cleanly: $endedCleanly, worked at all: '
    '$workedAtAll) — '
    '${plan.map((step) => '${step.content} [${step.status.name}]').join(' · ')}';

/// A persisted status is this enum's own [AgentPlanStatus] name; unknown reads as
/// pending — a step we can't place is one not started, never one shown as done.
AgentPlanStatus _planStatusByName(Object? raw) {
  for (final status in AgentPlanStatus.values) {
    if (status.name == raw) return status;
  }
  return AgentPlanStatus.pending;
}

/// ACP's live plan statuses (`pending`/`in_progress`/`completed`); unknown reads
/// as pending, so a step we can't place is never shown as done.
AgentPlanStatus _planStatusFromAcp(Object? raw) => switch (raw) {
  'in_progress' => AgentPlanStatus.active,
  'completed' => AgentPlanStatus.done,
  _ => AgentPlanStatus.pending,
};

/// How much the user has agreed to let the agent do to this computer — chosen in
/// the composer, and applied to every turn from then on.
///
/// It only governs the actions the agent *escalates*: running a command, and
/// changing a file. Reading, searching and looking things up online are always
/// allowed and never interrupt anyone.
enum AgentApprovalMode {
  /// Look, don't touch. The agent reads the project's files and answers about
  /// them; it never runs anything and never changes anything.
  readOnly,

  /// Plan first. The agent works out a step-by-step plan read-only and shows it,
  /// then waits for the user to approve before it touches anything — the whole
  /// plan is one yes, after which it carries it out asking per action (like
  /// [ask]). A middle ground between looking and doing.
  plan,

  /// Ask first: the agent stops and shows the command, or the change to the
  /// file, and waits for a yes. The default — nothing happens behind your back.
  ask,

  /// Do it: commands run and files change without asking. Fastest, and the one
  /// that can wreck things — the app says so where it's chosen.
  full,
}

/// How much of the agent's working-out the chat shows while it answers.
///
/// A live feed of shell commands is exactly what one user wants and noise to the
/// next: the app is built for people who don't read shell (§5), but the people
/// debugging it need the command that failed. One setting, three honest levels.
enum AgentDetailMode {
  /// Just that it is working. No step list — the "Thinking…" line and the answer.
  answer,

  /// What it is doing, in words: "Ran a command", the name of the tool. Enough
  /// to follow along without reading anyone's shell.
  steps,

  /// The steps with the command lines themselves — what actually ran.
  stepsCommands,
}

/// What the agent wants permission for.
enum AgentPermissionKind {
  /// Run a command on this computer.
  command,

  /// Write to a file — [AgentPermission.oldText] / [AgentPermission.newText]
  /// are what it looks like now and what it would become.
  edit,

  /// Anything else the agent asked for, and anything we couldn't read as one of
  /// the two above — a tool this app has no special way to draw.
  ///
  /// It still goes to the user, shown with the agent's own title and the raw
  /// request ([AgentPermission.command]). Refusing these unasked is what left an
  /// agent silently unable to work while the chat claimed it would ask first;
  /// a request we can't dress up is still one the user can read and judge.
  other,
}

/// What the user answered.
enum AgentPermissionChoice {
  /// Just this once.
  allowOnce,

  /// Every time in this chat, without asking again.
  allowForChat,

  /// No.
  refuse,
}

/// Something the agent can't do without the user's say-so: a command it wants to
/// run, or a change it wants to make to a file. It is *waiting* on the answer —
/// nothing happens until one comes back (and if none does, the answer is no).
///
/// Lives beside [AgentActivity] because the agent transport (Hermes over ACP)
/// raises these mid-turn; the chat puts them in front of the user.
class AgentPermission {
  const AgentPermission({
    required this.id,
    required this.kind,
    required this.summary,
    required this.options,
    this.command,
    this.path,
    this.oldText,
    this.newText,
  });

  /// The transport's id for the request, echoed back with the answer. Opaque.
  final Object id;

  final AgentPermissionKind kind;

  /// One plain line saying what it's for — the agent's own reason for the
  /// command ("Delete the build folder"), or what it would do to the file.
  final String summary;

  /// The command line, for [AgentPermissionKind.command].
  final String? command;

  /// The file, for [AgentPermissionKind.edit].
  final String? path;

  /// The file's current contents, or null when it doesn't exist yet.
  final String? oldText;

  /// What the agent wants the file to contain.
  final String? newText;

  final List<HermesPermissionOption> options;

  /// Whether the agent offered a "stop asking me in this chat" option — it isn't
  /// offered for file edits, so the choice must not be shown for them.
  bool get canAllowForChat =>
      options.any((o) => o.optionId == kAllowForChatOption);
}

/// Hermes's own id for "allow every time in this session" — the widest grant the
/// app hands out. `allow_always` (which Hermes persists to its config, forever,
/// with no way to take it back from this app) is deliberately never chosen.
const String kAllowForChatOption = 'allow_session';

/// One choice the agent offered for a permission request: its stable id and the
/// ACP kind hint (`allow_once` / `allow_always` / `reject_once` / `reject_always`).
typedef HermesPermissionOption = ({String optionId, String kind});
