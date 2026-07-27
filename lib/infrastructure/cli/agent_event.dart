import 'hermes_permission_policy.dart';

/// What kind of step the agent is running — a shell command, a look-up on the
/// web, the model's own reasoning, or any other tool. The kind picks the icon
/// in the activity feed.
enum AgentActivityKind { command, web, tool, thinking }

/// Lifecycle of one agent step, driving its live status indicator.
enum AgentActivityStatus { running, done, failed }

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
  });

  final String id;
  final AgentActivityKind kind;

  /// Short human label — the shell command, or the tool name.
  final String label;
  final AgentActivityStatus status;
}

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
    final content = json['content'];
    if (content is! String || content.trim().isEmpty) return null;
    return AgentPlanEntry(
      content: content.trim(),
      status: _planStatusByName(json['status']),
    );
  }
}

/// Parses an ACP `plan` update's `entries` into the agent's to-do list. Each
/// entry is `{content, status}` where status is ACP's own
/// `pending`/`in_progress`/`completed`; anything else reads as pending, and a
/// blank step is dropped. The list replaces the previous plan wholesale — Hermes
/// sends the full to-do state each time, not a delta.
List<AgentPlanEntry> parseAgentPlan(Object? entries) {
  if (entries is! List) return const [];
  final plan = <AgentPlanEntry>[];
  for (final entry in entries) {
    if (entry is! Map) continue;
    final content = entry['content'];
    if (content is! String || content.trim().isEmpty) continue;
    plan.add(
      AgentPlanEntry(
        content: content.trim(),
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
