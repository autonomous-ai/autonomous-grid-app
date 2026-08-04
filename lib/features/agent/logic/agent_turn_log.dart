import '../../../infrastructure/cli/command_log.dart';

/// What the Debug tab records for one agent turn spawned as a process.
///
/// [args] is the argv the agent CLI was given — taken from the same pure
/// builder the exec service runs, never re-typed, because a flag list written
/// twice is a flag list that stops matching. [workdir] is the folder the turn
/// opened in, [prompt] rides as the request body, and of [environment] only the
/// variable names travel: it carries the grid credential (see [envParam]).
CommandDetail agentTurnDetail({
  required List<String> args,
  required String workdir,
  required Map<String, String> environment,
  required String prompt,
}) => CommandDetail(
  args: args,
  params: {
    'folder': workdir,
    if (environment.isNotEmpty) 'env': envParam(environment),
  },
  requestBody: prompt,
);
