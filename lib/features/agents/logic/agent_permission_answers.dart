import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/hermes_permission_policy.dart';

/// What each answer to a permission request is called, in the order offered.
///
/// Every surface that asks — the window, the Grid Panel, a Telegram message —
/// is one question to the person answering, so all of them say it the same way
/// (§5): a card that reads "Allow once" in the window and "Yes" elsewhere is
/// two questions as far as they are concerned.
const Map<AgentPermissionChoice, String> kPermissionAnswerLabels = {
  AgentPermissionChoice.refuse: "Don't allow",
  AgentPermissionChoice.allowForChat: 'Allow in this chat',
  AgentPermissionChoice.allowOnce: 'Allow once',
};

/// One answer a surface may offer: the choice, the agent's option id that
/// delivers it, and its label.
typedef PermissionAnswer = ({
  AgentPermissionChoice choice,
  String optionId,
  String label,
});

/// The answers that may be offered for [request], in the order to draw them.
///
/// Built from the agent's own options rather than a fixed pair: what it offers
/// varies, and a surface that assumes two would draw a button for an answer
/// that was never on the table. Each entry is one the app can *deliver* —
/// [optionIdForChoice] resolved it against this very request — so no button
/// can turn into a silent no on the way back. That is also why this is not
/// [AgentPermission.options] copied out: the agent's `allow_always` is one this
/// app never picks (it would outlive the setting that allowed it), and offering
/// it would draw a button whose only possible outcome is a refusal.
List<PermissionAnswer> permissionAnswersFor(AgentPermission request) {
  final answers = <PermissionAnswer>[];
  final seen = <String>{};
  for (final entry in kPermissionAnswerLabels.entries) {
    final optionId = optionIdForChoice(entry.key, request.options);
    if (optionId == null || !seen.add(optionId)) continue;
    answers.add((choice: entry.key, optionId: optionId, label: entry.value));
  }
  return answers;
}
