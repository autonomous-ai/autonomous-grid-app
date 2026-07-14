import 'agent_event.dart';

/// The gate over what the agent may do to this computer.
///
/// Hermes classifies its own tool use: safe reads, web searches and benign
/// commands it auto-approves and never asks about. Only the actions that change
/// something raise an ACP permission request — a destructive shell command
/// (`toolCall.kind = "execute"`) or a file write (`"edit"`, carrying the diff).
///
/// Those are the ones **the user decides**, in the chat, before they happen: the
/// app can't judge whether rewriting a file is what they wanted, and silently
/// refusing left the agent unable to do the very thing a project folder is for.
/// Anything else — a kind we can't put in plain words in front of a person — is
/// refused, unasked. Deciding is not the same as rubber-stamping: nothing runs
/// until the user says so, and if there's nobody to ask (no chat listening), the
/// answer is no.
const safeToolKinds = {'read', 'search', 'fetch', 'think'};

/// The kinds the user is asked about, because the app can show exactly what
/// would happen: the command line, or the change to the file.
const askableToolKinds = {'execute', 'edit'};

/// Hermes's own id for "allow every time in this session" — the widest grant the
/// app hands out. `allow_always` (which Hermes persists to its config, forever,
/// with no way to take it back from this app) is deliberately never chosen.
const String kAllowForChatOption = 'allow_session';

/// One choice the agent offered for a permission request: its stable id and the
/// ACP kind hint (`allow_once` / `allow_always` / `reject_once` / `reject_always`).
typedef HermesPermissionOption = ({String optionId, String kind});

/// What to do with a permission request the agent raised.
sealed class HermesPermissionDecision {
  const HermesPermissionDecision();
}

/// Answer yes without troubling the user — a read-only action.
class HermesAllow extends HermesPermissionDecision {
  const HermesAllow(this.optionId);
  final String optionId;
}

/// Answer no. [optionId] is the reject option to send, or null to cancel the
/// request outright when the agent offered none.
class HermesRefuse extends HermesPermissionDecision {
  const HermesRefuse(this.optionId);
  final String? optionId;
}

/// Put it to the user, in the chat, and wait for their answer.
class HermesAskUser extends HermesPermissionDecision {
  const HermesAskUser();
}

/// How to answer the permission request for a [toolKind]: safe kinds are allowed
/// outright, the ones we can explain are put to the user, and anything else fails
/// closed.
HermesPermissionDecision decideHermesPermission({
  required String toolKind,
  required List<HermesPermissionOption> options,
}) {
  if (safeToolKinds.contains(toolKind)) {
    final allow = _byKind(options, const ['allow_once', 'allow_always']);
    // No way to say yes → say no. Never fall through to "approve anyway".
    return allow == null ? const HermesRefuse(null) : HermesAllow(allow);
  }
  if (askableToolKinds.contains(toolKind)) return const HermesAskUser();
  return HermesRefuse(refuseOption(options));
}

/// The option that says no, or null when the agent offered none (the request is
/// then cancelled, which Hermes also reads as no).
String? refuseOption(List<HermesPermissionOption> options) =>
    _byKind(options, const ['reject_once', 'reject_always']);

/// The option id for what the user chose, or null to cancel (which denies).
String? optionIdForChoice(
  AgentPermissionChoice choice,
  List<HermesPermissionOption> options,
) => switch (choice) {
  AgentPermissionChoice.allowOnce => _byKind(options, const ['allow_once']),
  AgentPermissionChoice.allowForChat => _byId(options, kAllowForChatOption),
  AgentPermissionChoice.refuse => refuseOption(options),
};

/// The options on an ACP permission request, dropping anything malformed.
List<HermesPermissionOption> parsePermissionOptions(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final option in raw)
      if (option is Map)
        (optionId: _string(option['optionId']), kind: _string(option['kind'])),
  ];
}

/// The permission request to put in front of the user, or null when it isn't one
/// we can show honestly (no command to display, no file to name) — the service
/// then refuses it rather than asking about something it can't describe.
AgentPermission? parseAgentPermission({
  required Object id,
  required Object? params,
}) {
  if (params is! Map) return null;
  final toolCall = params['toolCall'];
  if (toolCall is! Map) return null;
  final options = parsePermissionOptions(params['options']);

  if (toolCall['kind'] == 'execute') {
    final raw = toolCall['rawInput'];
    final command = _string(raw is Map ? raw['command'] : null);
    if (command.isEmpty) return null;
    final description = _string(raw is Map ? raw['description'] : null);
    return AgentPermission(
      id: id,
      kind: AgentPermissionKind.command,
      summary: description.isEmpty ? 'Run this on your computer' : description,
      command: command,
      options: options,
    );
  }

  if (toolCall['kind'] == 'edit') {
    final diff = _firstDiff(toolCall['content']);
    if (diff == null) return null;
    final path = _string(diff['path']);
    if (path.isEmpty) return null;
    final oldText = diff['oldText'] ?? diff['old_text'];
    final newText = diff['newText'] ?? diff['new_text'];
    return AgentPermission(
      id: id,
      kind: AgentPermissionKind.edit,
      summary: oldText == null ? 'Create this file' : 'Change this file',
      path: path,
      oldText: oldText is String ? oldText : null,
      newText: _string(newText),
      options: options,
    );
  }
  return null;
}

/// The first diff block on the tool call — where an edit request carries the
/// file, its current contents and what the agent wants them to become.
Map<Object?, Object?>? _firstDiff(Object? content) {
  if (content is! List) return null;
  for (final block in content) {
    if (block is Map && block['type'] == 'diff') return block;
  }
  return null;
}

String? _byKind(List<HermesPermissionOption> options, List<String> kinds) {
  for (final kind in kinds) {
    for (final option in options) {
      if (option.kind == kind) return option.optionId;
    }
  }
  return null;
}

String? _byId(List<HermesPermissionOption> options, String optionId) {
  for (final option in options) {
    if (option.optionId == optionId) return option.optionId;
  }
  return null;
}

String _string(Object? raw) => raw is String ? raw : '';
