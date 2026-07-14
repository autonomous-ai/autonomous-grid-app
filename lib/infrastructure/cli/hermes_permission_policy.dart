/// A backstop over Hermes's own dangerous-command detection: whatever the agent
/// *escalates* for approval, we refuse.
///
/// Hermes classifies its own tool use — safe reads, web searches, and benign
/// commands (running an installed skill, curling an API) it auto-approves and
/// never asks about; only genuinely dangerous actions raise an ACP permission
/// request: destructive shell (`rm -rf`, `chmod 777`, `curl | sh`, killing
/// Hermes) with `toolCall.kind = "execute"`, and file writes with `"edit"`. We
/// deny exactly those. So the agent can look things up and run the skills the
/// app ships, but can't run a destructive command or silently rewrite the user's
/// files.
///
/// This is the gate, not a suggestion: the ACP layer replaced a blanket
/// auto-approve that rubber-stamped even those dangerous requests. Granting
/// write/execute on the escalated actions is a deliberate future opt-in — flip a
/// kind out of the refused set.
const safeToolKinds = {'read', 'search', 'fetch', 'think'};

/// One choice the agent offered for a permission request: its stable id and the
/// ACP kind hint (`allow_once` / `allow_always` / `reject_once` / `reject_always`).
typedef HermesPermissionOption = ({String optionId, String kind});

/// The `optionId` to answer an ACP permission request with, or null to cancel it
/// outright (deny) when the agent offered no option of the kind we need.
///
/// [toolKind] is the ACP tool-call category the permission is for. A safe kind
/// picks an allow option; anything else picks a reject option. Falling back to
/// null (cancel) rather than the first option matters: for a dangerous action
/// with no explicit reject option, we must still not approve it.
String? decideHermesPermission({
  required String toolKind,
  required List<HermesPermissionOption> options,
}) {
  final wanted = safeToolKinds.contains(toolKind)
      ? const ['allow_once', 'allow_always']
      : const ['reject_once', 'reject_always'];
  for (final want in wanted) {
    for (final option in options) {
      if (option.kind == want) return option.optionId;
    }
  }
  return null;
}
