import '../../../infrastructure/cli/command_log.dart';

/// What the Debug tab records for one agent turn spawned as a process.
///
/// [args] is the argv the agent CLI was given, program first — taken from the
/// same pure builder the exec service runs, never re-typed, because a flag list
/// written twice is a flag list that stops matching. [workdir] is the folder the
/// turn opened in, and of [environment] only the variable names travel: it
/// carries the grid credential (see [CommandDetail.envKeys]).
///
/// [prompt] is recorded as the request body because that is what it is — both
/// agents take it on **stdin**, not in argv, so a copied command has to pipe it
/// back in to be the same turn.
CommandDetail agentTurnDetail({
  required List<String> args,
  required String workdir,
  required Map<String, String> environment,
  required String prompt,
}) => CommandDetail(
  args: args,
  params: {'folder': workdir},
  envKeys: environment.keys.toList(growable: false),
  requestBody: prompt,
);
