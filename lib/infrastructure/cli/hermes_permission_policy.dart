import 'agent_event.dart';

/// The gate over what the agent may do to this computer.
///
/// Hermes classifies its own tool use: safe reads, web searches and benign
/// commands it auto-approves and never asks about. Only the actions that change
/// something raise an ACP permission request — typically a shell command
/// (`toolCall.kind = "execute"`) or a file write (`"edit"`, carrying the diff).
///
/// Everything that isn't on this list is **the user's decision**, in the chat,
/// before it happens — including a kind this app has never seen. Refusing those
/// unasked was a quiet no in a chat that promised to ask: the agent lost tools
/// nobody chose to take away, and said so only by narrating its own failure.
/// Deciding is not the same as rubber-stamping: nothing runs until the user says
/// so, and if there's nobody to ask (no chat listening), the answer is still no.
const safeToolKinds = {'read', 'search', 'fetch', 'think'};

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

/// How to answer the permission request for a [toolKind], under the [mode] the
/// user chose in the composer: safe kinds are allowed outright, and **every
/// other kind follows the mode** — the known ones and the ones we've never seen
/// alike.
///
/// An unknown kind used to fail closed here. That reads as caution and behaves
/// as a lie: the composer says "Ask before acting", and the user was never
/// asked. A tool we can't draw prettily is still one they can read (see
/// [parseAgentPermission]'s fallback), so the answer is theirs to give.
///
/// Even on [AgentApprovalMode.full] the yes is a *one-off* — never Hermes's
/// "always", which it would persist to its own config and honour long after the
/// user switched the mode back.
HermesPermissionDecision decideHermesPermission({
  required String toolKind,
  required List<HermesPermissionOption> options,
  AgentApprovalMode mode = AgentApprovalMode.ask,
}) {
  if (safeToolKinds.contains(toolKind)) return _allowOrRefuse(options);

  return switch (mode) {
    // Plan's planning turn runs with the session forced to read-only (the
    // sender does that), so this never actually sees `plan`; treated as
    // read-only for safety if it ever did — a plan turn touches nothing.
    AgentApprovalMode.readOnly ||
    AgentApprovalMode.plan => HermesRefuse(refuseOption(options)),
    AgentApprovalMode.ask => const HermesAskUser(),
    AgentApprovalMode.full => _allowOrRefuse(options),
  };
}

/// Yes, once — or no, when the agent offered no way to say yes. Never falls
/// through to "approve anyway".
HermesPermissionDecision _allowOrRefuse(List<HermesPermissionOption> options) {
  final allow = _byKind(options, const ['allow_once', 'allow_always']);
  return allow == null ? const HermesRefuse(null) : HermesAllow(allow);
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

/// The permission request to put in front of the user, or null only when the
/// message carries no tool call at all — there is then nothing to ask *about*.
///
/// A command and a file edit get their own shapes, because the app can show
/// exactly what would happen. Everything else — an unfamiliar kind, or one of
/// those two arriving without the field we draw it from — falls through to
/// [AgentPermissionKind.other] and is shown as the agent's own title over the
/// raw request. Returning null there (and refusing) was the quiet no that let a
/// blocked agent look like a broken one.
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
    if (command.isNotEmpty) {
      final description = _string(raw is Map ? raw['description'] : null);
      return AgentPermission(
        id: id,
        kind: AgentPermissionKind.command,
        summary: description.isEmpty
            ? 'Run this on your computer'
            : description,
        command: command,
        options: options,
      );
    }
  }

  if (toolCall['kind'] == 'edit') {
    final diff = _firstDiff(toolCall['content']);
    final path = _string(diff?['path']);
    if (diff != null && path.isNotEmpty) {
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
  }

  return AgentPermission(
    id: id,
    kind: AgentPermissionKind.other,
    summary: describeToolCall(toolCall),
    command: _rawRequest(toolCall),
    options: options,
  );
}

/// One line naming what the agent asked for: its own title for the tool call,
/// else the kind it gave, else a plain fallback — so the card never heads a
/// question with an empty string.
String describeToolCall(Map<Object?, Object?> toolCall) {
  final title = _string(toolCall['title']);
  if (title.isNotEmpty) return title;
  final kind = _string(toolCall['kind']);
  return kind.isEmpty ? 'The assistant wants to do something' : kind;
}

/// What the agent actually sent, for the user to read before deciding: its own
/// text content when it wrote any, else the raw input it passed the tool.
///
/// Shown verbatim rather than summarised. This branch exists precisely because
/// the app doesn't understand the request — putting our own words on it would be
/// inventing a description of something we can't read.
String _rawRequest(Map<Object?, Object?> toolCall) {
  final text = _toolCallText(toolCall['content']);
  if (text.isNotEmpty) return text;
  final raw = toolCall['rawInput'];
  return raw == null ? '' : '$raw';
}

/// The text blocks on a tool call, joined — how Hermes describes a call it isn't
/// sending a diff for.
String _toolCallText(Object? content) {
  if (content is! List) return '';
  final lines = <String>[];
  for (final block in content) {
    if (block is! Map) continue;
    final inner = block['content'];
    final text = _string(inner is Map ? inner['text'] : block['text']);
    if (text.isNotEmpty) lines.add(text);
  }
  return lines.join('\n');
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
