import 'agent_event.dart';

/// The decisions `codex app-server` accepts on an approval request, and the
/// option ids this app maps them to.
///
/// Codex offers `acceptForSession` itself — a yes it remembers for the rest of
/// the thread — so unlike Claude Code this transport doesn't need the app to
/// remember anything: the thread and the chat are the same thing here.
const String kCodexAccept = 'accept';
const String kCodexAcceptForSession = 'acceptForSession';
const String kCodexDecline = 'decline';

/// The approval requests this app knows how to answer.
const String kCodexCommandApproval = 'item/commandExecution/requestApproval';
const String kCodexFileChangeApproval = 'item/fileChange/requestApproval';

/// The request Codex is blocked on, or null for a method this app doesn't
/// answer.
///
/// A command carries everything needed to judge it — the exact line, where it
/// would run — in the request itself. A file change does **not**: its request
/// names only the item, so [item] is the `fileChange` item remembered from the
/// `item/started` notification that preceded it. Without it there is nothing to
/// show but a path, so the caller keeps them.
///
/// Verified against the pinned build on 2026-08-18: a command that had to
/// escalate arrived as [kCodexCommandApproval] with `command`, `cwd`,
/// `commandActions` and `availableDecisions`, and answering `accept` ran it. A
/// command Codex judges safe (`echo hi`) is never sent here at all — it decides
/// that itself, exactly as Hermes does, which is why the app's own copy must
/// never promise that *every* command is shown.
AgentPermission? parseCodexApproval({
  required Object id,
  required String method,
  required Map<String, dynamic> params,
  Map<String, dynamic>? item,
}) => switch (method) {
  kCodexCommandApproval => _command(id, params),
  kCodexFileChangeApproval => _fileChange(id, params, item),
  _ => null,
};

AgentPermission _command(Object id, Map<String, dynamic> params) {
  final command = '${params['command'] ?? ''}'.trim();
  final reason = '${params['reason'] ?? ''}'.trim();
  return AgentPermission(
    id: id,
    kind: AgentPermissionKind.command,
    summary: reason.isNotEmpty ? reason : command,
    command: command,
    options: codexApprovalOptions(params['availableDecisions']),
  );
}

/// A patch, shown as the patch.
///
/// Deliberately [AgentPermissionKind.other] rather than `edit`: the card's edit
/// shape draws a before/after, and what Codex hands over is a *unified diff* —
/// there is no honest "after" without applying it. So the user is shown the diff
/// itself, over the files it touches, rather than a comparison the app would
/// have to invent.
AgentPermission _fileChange(
  Object id,
  Map<String, dynamic> params,
  Map<String, dynamic>? item,
) {
  final changes = codexChangedFiles(item);
  final reason = '${params['reason'] ?? ''}'.trim();
  return AgentPermission(
    id: id,
    kind: AgentPermissionKind.other,
    summary: reason.isNotEmpty ? reason : _changeSummary(changes),
    command: _diffText(changes),
    options: codexApprovalOptions(params['availableDecisions']),
  );
}

/// The files in a remembered `fileChange` item, each with the patch that would
/// be applied to it.
List<({String path, String diff})> codexChangedFiles(
  Map<String, dynamic>? item,
) {
  final raw = item?['changes'];
  if (raw is! List) return const [];
  return [
    for (final entry in raw)
      if (entry is Map && '${entry['path'] ?? ''}'.trim().isNotEmpty)
        (path: '${entry['path']}'.trim(), diff: '${entry['diff'] ?? ''}'),
  ];
}

String _changeSummary(List<({String path, String diff})> changes) =>
    switch (changes.length) {
      0 => 'Change a file',
      1 => 'Change ${changes.single.path}',
      final count => 'Change $count files',
    };

String _diffText(List<({String path, String diff})> changes) => changes
    .map((change) => '${change.path}\n${change.diff}'.trimRight())
    .join('\n\n');

/// The answers to offer, in the ACP shape the one card speaks — built from what
/// Codex says it will accept for *this* request, never from a fixed list: the
/// decisions differ between a command and a patch, and offering one the server
/// would reject is a button that does nothing.
List<HermesPermissionOption> codexApprovalOptions(Object? availableDecisions) {
  final available = <String>{
    if (availableDecisions is List)
      for (final decision in availableDecisions)
        if (decision is String) decision,
  };
  // An empty list means the build didn't say. Falling back to the two every
  // decision set has carried is better than a card with no buttons.
  final offered = available.isEmpty ? {kCodexAccept, kCodexDecline} : available;
  return [
    if (offered.contains(kCodexAccept))
      const (optionId: kCodexAccept, kind: 'allow_once'),
    if (offered.contains(kCodexAcceptForSession))
      const (optionId: kAllowForChatOption, kind: 'allow_always'),
    if (offered.contains(kCodexDecline))
      const (optionId: kCodexDecline, kind: 'reject_once'),
  ];
}

/// The JSON-RPC result that answers [method] with the option the user chose —
/// or with a decline, which is also what an unanswered card comes to.
///
/// The app's own "allow in this chat" id is translated back to Codex's
/// `acceptForSession` here, so the chat and the thread agree on what was
/// granted.
Map<String, Object?> codexApprovalResult({
  required String method,
  required String? optionId,
}) => {'decision': codexDecisionFor(optionId)};

String codexDecisionFor(String? optionId) => switch (optionId) {
  kCodexAccept => kCodexAccept,
  kAllowForChatOption || kCodexAcceptForSession => kCodexAcceptForSession,
  _ => kCodexDecline,
};
