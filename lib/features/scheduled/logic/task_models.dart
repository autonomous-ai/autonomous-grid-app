import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_model_support.dart';
import '../../network/logic/node_display.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';

/// The models a scheduled task can be pinned to, router first.
///
/// Narrower than the chat picker on two counts, and both are about a run nobody
/// is watching:
///
///  - **text only.** The image and video modes are Playground buttons, not
///    models — a task pinned to one would have no chat endpoint to call.
///  - **only what the assistant can answer with.** A Claude or Codex seat is
///    that vendor's own CLI behind the relay; pointed at one, a task comes back
///    with the tool call typed out instead of a report (03/08) and is recorded
///    as a success (see [agentSupportsModel]).
///
/// `auto` leads because it is the answer that survives a machine going off — the
/// grid picks per run. Pure so the list the dialog offers is unit-tested.
List<PlaygroundModelOption> taskModelOptions(
  List<PlaygroundModelOption> options,
) {
  final usable = [
    for (final option in options)
      if (option.modality == PlaygroundModality.text &&
          agentSupportsModel(AgentTool.hermes, option.id))
        option,
  ];
  // Built rather than sorted: `List.sort` isn't stable, and the rest of the list
  // has to stay in the order the grid gave it.
  return List.unmodifiable([
    for (final option in usable)
      if (option.id == kAutoModelId) option,
    for (final option in usable)
      if (option.id != kAutoModelId) option,
  ]);
}

/// The model a new task starts on: what the user last chatted with when it's on
/// offer, else the router, else the first model there is.
///
/// Their last chat model is the closest thing to a stated preference the dialog
/// has; falling back to `auto` rather than to an arbitrary first entry keeps a
/// task the user didn't think about running on whatever the grid can serve.
String defaultTaskModel(
  List<PlaygroundModelOption> options,
  String? preferred,
) {
  if (options.isEmpty) return '';
  final wanted = preferred?.trim();
  for (final option in options) {
    if (wanted != null && option.id == wanted) return option.id;
  }
  return options.first.id;
}
