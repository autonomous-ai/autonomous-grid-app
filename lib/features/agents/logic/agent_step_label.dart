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
