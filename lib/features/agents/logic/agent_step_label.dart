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
  var thoughts = 0;
  var others = 0;
  for (final step in steps) {
    switch (step.kind) {
      case AgentActivityKind.command:
        commands++;
      case AgentActivityKind.web:
        searches++;
      case AgentActivityKind.thinking:
        thoughts++;
      case AgentActivityKind.tool:
        switch (step.tool) {
          case 'Read' || 'NotebookRead' || 'read' || 'read_file':
            reads++;
          case 'Write' || 'Edit' || 'NotebookEdit' || 'write' || 'edit':
            edits++;
          default:
            others++;
        }
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
