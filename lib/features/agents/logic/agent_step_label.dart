import '../../../infrastructure/cli/agent_event.dart';

/// How one step in the activity feed reads at the chosen level of detail.
///
/// [AgentDetailMode.stepsCommands] shows what actually ran, which is what the
/// feed always did. [AgentDetailMode.steps] keeps the same rows but says them in
/// words — the app is for people who don't read shell (§5), and a live column of
/// `rg -n "foo" lib | head -20` tells them nothing except that something
/// technical is happening.
///
/// Naming the program rather than dropping to a bare "Ran a command" is the
/// point: "Ran rg" still says *what kind* of thing it did, which is the part a
/// non-technical user can follow.
///
/// Pure, so what each level says is tested rather than eyeballed.
String agentStepLabel(AgentActivity step, AgentDetailMode mode) {
  if (mode == AgentDetailMode.stepsCommands) return step.label;
  return switch (step.kind) {
    AgentActivityKind.command => _ranLabel(step.label),
    AgentActivityKind.web => 'Searched the web',
    // A tool's label is already its name, not a command line — nothing to hide.
    AgentActivityKind.tool || AgentActivityKind.thinking => step.label,
  };
}

/// "Ran rg" for `rg -n "foo" lib`, "Ran a command" when there's no program to
/// name (an empty label, or a line that opens with a shell construct).
String _ranLabel(String command) {
  final program = commandProgram(command);
  return program.isEmpty ? 'Ran a command' : 'Ran $program';
}

/// The program a shell command runs, bare: no path, no arguments, and no
/// leading `VAR=value` assignments (`FOO=1 /usr/bin/env python x.py` → `env`).
///
/// Empty when there is nothing that reads as a program — the caller says "a
/// command" rather than printing a fragment.
String commandProgram(String command) {
  for (final token in command.trim().split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    // An environment assignment prefixes the command; keep looking.
    if (_assignment.hasMatch(token)) continue;
    // A pipe or redirect is punctuation, not a program — step over it and name
    // whatever it feeds ("| head -20" ran `head`, and saying so beats "a
    // command").
    if (_punctuation.hasMatch(token)) continue;
    final program = token.split('/').last;
    return _quotes.hasMatch(program) ? '' : program;
  }
  return '';
}

final _assignment = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');
final _punctuation = RegExp(r'^[|&;<>(){}]');
final _quotes = RegExp(r'''^["']''');

/// What the app separates a tool's name from its subject with. Every agent
/// words a step differently — `Bash · cd …`, `terminal: ls -la`, `read: /path` —
/// so the row splits on whichever of these the label used rather than on one
/// agent's punctuation.
final _labelSplit = RegExp(r'\s+·\s+|:\s+');

/// The bold half of a step row: what kind of thing this step is.
///
/// A row is read in two inks — this, then [agentStepDetail] beside it — because
/// the two answer different questions. "Which tool" is the one a person scans a
/// column of steps for, and it is short and repeats; "on what" is long, varies
/// every row, and is the first thing to give way when the window narrows.
///
/// While a step is running it is said as an action in progress ("Reading",
/// "Running"): a column of finished rows and a live one look identical
/// otherwise, and the spinner beside it is 12px of the only difference.
String agentStepTitle(AgentActivity step) {
  final running = step.status == AgentActivityStatus.running;
  if (step.kind == AgentActivityKind.thinking) {
    return running ? 'Thinking' : 'Thought';
  }
  final tool = step.tool?.trim() ?? '';
  final name = tool.isNotEmpty ? tool : _labelHead(step.label);
  final verb = running ? _gerund(name, step.kind) : null;
  return verb ?? (name.isEmpty ? 'Tool' : name);
}

/// The quiet half of a step row: what the step is *about* — the command, the
/// file, the query.
///
/// Empty at [AgentDetailMode.steps], where the point of the level is that the
/// shell stays out of sight, and empty for a thought (whose text is the whole
/// step, and belongs in the fold rather than clipped into one line).
String agentStepDetail(AgentActivity step, AgentDetailMode mode) {
  if (mode != AgentDetailMode.stepsCommands) return '';
  if (step.kind == AgentActivityKind.thinking) return '';
  final label = step.label.trim();
  final tool = step.tool?.trim() ?? '';
  // Cut at the FIRST separator only. Splitting on every one of them and joining
  // the pieces back with a space rewrote the thing it was quoting: a step
  // labelled `Bash · git commit -m "fix: crash"` came out as
  // `git commit -m "fix crash"` — a command that was never run, shown as the
  // command that ran.
  final cut = _labelSplit.firstMatch(label);
  if (cut != null && (tool.isEmpty || label.substring(0, cut.start) == tool)) {
    return label.substring(cut.end).trim();
  }
  return label == tool ? '' : label;
}

/// The first word of a label, for a lane that never named its tool.
String _labelHead(String label) {
  final cut = _labelSplit.firstMatch(label);
  return (cut == null ? label : label.substring(0, cut.start)).trim();
}

/// A tool name said as something happening now. Null when there is no natural
/// one — an MCP server's tool is called whatever it is called, and "Doing
/// mcp__chrome__navigate_page" is worse than the name on its own.
String? _gerund(String tool, AgentActivityKind kind) => switch (tool) {
  'Read' || 'NotebookRead' => 'Reading',
  'Write' => 'Writing',
  'Edit' || 'NotebookEdit' => 'Editing',
  'Grep' || 'Glob' || 'Search' => 'Searching',
  'Task' => 'Working',
  _ => switch (kind) {
    AgentActivityKind.command => 'Running',
    AgentActivityKind.web => 'Searching the web',
    _ => null,
  },
};

/// What kind of work a step did, whichever agent ran it.
///
/// Four agents name the same act four ways — a shell call arrives as `Bash`
/// from Claude Code, `Shell` from Codex, `terminal` from Hermes and `bash` from
/// Pi — so anything that reasons about *what a step did* needs a synonym table.
/// One table, read by both the glyph in the step row and the summary a folded
/// run collapses into: written twice, adding a fifth agent means updating one
/// and leaving the other to disagree, and the disagreement surfaces as a wrench
/// sitting beside the words "read 6 files".
///
/// [AgentActivity.kind] wins wherever it is decisive. The transports already
/// classify shell, web and thinking themselves, and a step one of them called a
/// command is a command whatever its tool is named; the table only has to sort
/// the generic `tool` bucket, which is where each of them puts the rest.
enum AgentToolFamily {
  read,
  write,
  edit,
  search,
  list,
  shell,
  web,
  fetch,
  subAgent,
  todo,
  mcp,
  think,

  /// Reaching for one of the skills Grid installs into the agent (`grid-web`,
  /// `grid-host`, …). Its own family rather than a generic tool: five of them
  /// ship with every agent, so this is one of the commonest rows in the feed,
  /// and it was drawing the fallback wrench.
  skill,

  /// A tool no agent here has claimed. Kept rather than guessed at: a name we
  /// don't know still ran and still deserves a row, and a glyph picked by
  /// resemblance would state something about it that nobody checked.
  other,
}

/// The family [step] belongs to — its [AgentActivity.kind] where that decides
/// it, else its tool's own name.
AgentToolFamily agentToolFamily(AgentActivity step) => switch (step.kind) {
  AgentActivityKind.command => AgentToolFamily.shell,
  AgentActivityKind.web => AgentToolFamily.web,
  AgentActivityKind.thinking => AgentToolFamily.think,
  // A lane that never named its tool leaves the name at the head of the label
  // (see [agentStepTitle], which falls back the same way).
  AgentActivityKind.tool => _familyOfTool(switch (step.tool?.trim() ?? '') {
    '' => _labelHead(step.label),
    final named => named,
  }),
};

/// The family a tool's own name puts it in, matched case-insensitively across
/// every spelling the four agents use.
AgentToolFamily _familyOfTool(String name) {
  final key = name.trim().toLowerCase();
  // An MCP tool is named by whoever wrote the server, so it is recognised by
  // its prefix rather than listed: `mcp__gmail__send_message` is one of an
  // unbounded set, and the prefix is the only part that is ours to rely on.
  if (key.startsWith('mcp__') || key.startsWith('mcp_tool')) {
    return AgentToolFamily.mcp;
  }
  return _kToolFamilies[key] ?? AgentToolFamily.other;
}

/// Tool name → family, lower-cased. Every entry is a name one of the four
/// agents actually sends; nothing here is speculative vocabulary.
const Map<String, AgentToolFamily> _kToolFamilies = {
  'read': AgentToolFamily.read,
  'read_file': AgentToolFamily.read,
  'notebookread': AgentToolFamily.read,
  'write': AgentToolFamily.write,
  'write_file': AgentToolFamily.write,
  'edit': AgentToolFamily.edit,
  'multiedit': AgentToolFamily.edit,
  'notebookedit': AgentToolFamily.edit,
  'patch': AgentToolFamily.edit,
  'apply_patch': AgentToolFamily.edit,
  'grep': AgentToolFamily.search,
  'glob': AgentToolFamily.search,
  'search': AgentToolFamily.search,
  'search_files': AgentToolFamily.search,
  'find': AgentToolFamily.search,
  'ls': AgentToolFamily.list,
  'list_files': AgentToolFamily.list,
  'bash': AgentToolFamily.shell,
  'bashoutput': AgentToolFamily.shell,
  'killshell': AgentToolFamily.shell,
  'shell': AgentToolFamily.shell,
  'terminal': AgentToolFamily.shell,
  'command_execution': AgentToolFamily.shell,
  'websearch': AgentToolFamily.web,
  'web search': AgentToolFamily.web,
  'web_search': AgentToolFamily.web,
  'webfetch': AgentToolFamily.fetch,
  'web_fetch': AgentToolFamily.fetch,
  'fetch': AgentToolFamily.fetch,
  'browser': AgentToolFamily.fetch,
  'task': AgentToolFamily.subAgent,
  'todowrite': AgentToolFamily.todo,
  'todo': AgentToolFamily.todo,
  'todo_list': AgentToolFamily.todo,
  'skill': AgentToolFamily.skill,
  'thinking': AgentToolFamily.think,
  'reasoning': AgentToolFamily.think,
};

/// **TODO(BE): nothing draws this right now.** It summarised a folded run of
/// steps, and the fold was taken out on 2026-08-17 when the steps went flat —
/// deliberately and, per the request, temporarily. Kept rather than deleted
/// because it is the wording a fold needs the moment one comes back, and it is
/// measured copy (the clause order, the spelled-out count of one) that would be
/// re-derived wrong. If a fold has not returned by the time anyone reads this,
/// delete it — an uncalled function with no test is exactly what rots.
///
/// One line for a run of steps: "Read 6 files, ran a command".
///
/// It stands in for the rows while they are folded away — and folded is *all*
/// the rows now — so it has to say what happened rather than how much of it
/// there was. "8 steps" is a number the reader can already see the size of and
/// says nothing about whether their computer was touched.
///
/// **Biggest clause first**, which is the order Claude Desktop uses and the
/// order that reads right: what a run mostly did is the thing worth leading
/// with, and the one-off at the end is an aside ("read 6 files, ran a command"
/// — not "ran a command, read 6 files", which promises a run about commands).
/// Ties keep a fixed order so two runs of the same shape read the same way.
///
/// A count of one is spelled as a word — "ran a command", not "ran 1 command" —
/// because the digit is there to be compared and there is nothing to compare it
/// to.
///
/// Pure, so what it says is tested rather than eyeballed.
String describeStepRun(List<AgentActivity> steps) {
  var commands = 0;
  var reads = 0;
  var edits = 0;
  var searches = 0;
  var skills = 0;
  var thoughts = 0;
  var others = 0;
  // Coarser than [AgentToolFamily] on purpose: this sentence is about what the
  // run did *to* the computer, so writing a file and editing one are the same
  // clause, and looking something up is one whether it was searched or opened.
  for (final step in steps) {
    switch (agentToolFamily(step)) {
      case AgentToolFamily.shell:
        commands++;
      case AgentToolFamily.web || AgentToolFamily.fetch:
        searches++;
      case AgentToolFamily.think:
        thoughts++;
      case AgentToolFamily.read:
        reads++;
      case AgentToolFamily.write || AgentToolFamily.edit:
        edits++;
      case AgentToolFamily.skill:
        skills++;
      case AgentToolFamily.search ||
          AgentToolFamily.list ||
          AgentToolFamily.subAgent ||
          AgentToolFamily.todo ||
          AgentToolFamily.mcp ||
          AgentToolFamily.other:
        others++;
    }
  }
  // The tie-break order when two clauses have the same count: what the run did
  // *to* the computer first, what it merely looked at last.
  final clauses = <({int count, String text})>[
    if (reads > 0) (count: reads, text: _count(reads, 'read', 'file')),
    if (edits > 0) (count: edits, text: _count(edits, 'changed', 'file')),
    if (commands > 0)
      (count: commands, text: _count(commands, 'ran', 'command')),
    if (searches > 0)
      (
        count: searches,
        text: searches == 1
            ? 'searched the web'
            : 'searched the web $searches times',
      ),
    // Named rather than folded into "used a tool": a skill is a thing the user
    // can go and look at — Grid installs five of them and the Skills screen
    // lists them — so saying which kind of help the agent reached for is worth
    // one clause.
    if (skills > 0) (count: skills, text: _count(skills, 'used', 'skill')),
    if (others > 0) (count: others, text: _count(others, 'used', 'tool')),
  ];
  // Thinking is counted only when it is all that happened. An agent thinks
  // between every pair of steps, so "and thought 7 times" on a run that also
  // built something says nothing about what it did.
  if (clauses.isEmpty && thoughts > 0) {
    return thoughts == 1 ? 'Thought about it' : 'Thought $thoughts times';
  }
  if (clauses.isEmpty) {
    return '${steps.length} ${_plural(steps.length, 'step')}';
  }
  // Stable by construction: `sort` is not guaranteed stable, so the fixed order
  // above is carried into the comparison rather than relied on to survive it.
  final ordered =
      [for (var i = 0; i < clauses.length; i++) (index: i, clause: clauses[i])]
        ..sort((a, b) {
          final byCount = b.clause.count.compareTo(a.clause.count);
          return byCount != 0 ? byCount : a.index.compareTo(b.index);
        });
  // One sentence, and the capital belongs to whichever clause opens it — a run
  // that only read files started "read 2 files", lowercase, because the capital
  // was welded to the shell clause that wasn't there.
  return _capitalized([for (final e in ordered) e.clause.text].join(', '));
}

/// "read 6 files" · "read a file" — the digit only earns its place when there is
/// something to compare it against.
String _count(int count, String verb, String noun) =>
    count == 1 ? '$verb a $noun' : '$verb $count ${_plural(count, noun)}';

String _capitalized(String line) =>
    line.isEmpty ? line : line[0].toUpperCase() + line.substring(1);

String _plural(int count, String word) => count == 1 ? word : '${word}s';
