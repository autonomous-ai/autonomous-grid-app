import 'hermes_permission_policy.dart';

/// What kind of step the agent is running — a shell command, a look-up on the
/// web, or any other tool. The kind picks the icon in the activity feed.
enum AgentActivityKind { command, web, tool }

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
