import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/hermes_permission_policy.dart';
import '../../../infrastructure/logging/app_log.dart';
import 'agent_permissions.dart';
import 'agent_session_grants.dart';

/// Answer one request an agent has stopped on — or put it to the user.
///
/// One function for every agent that can ask. Hermes decides inside its own ACP
/// session (it holds the option ids the protocol handed it); Claude Code and
/// Codex come through here, so the rule the user chose in the composer means the
/// same thing whichever agent is answering.
///
/// [grantKey] is what "Allow in this chat" would remember, for a transport that
/// can't remember it itself — Claude Code. Null for Codex, which holds its own
/// `acceptForSession` for the life of the thread.
///
/// Whatever the outcome, it is written to the log as well as acted on: a
/// permission answered on the user's behalf is exactly the kind of thing that
/// has to be readable afterwards.
void decideAgentPermission({
  required Ref ref,
  required String agent,
  required String chat,
  required AgentPermission request,
  required AgentApprovalMode approval,
  required void Function(String? optionId) answer,
  String? grantKey,
}) {
  final log = ref.read(appLogProvider);
  final grants = ref.read(agentSessionGrantsProvider.notifier);
  final allow = optionIdForChoice(
    AgentPermissionChoice.allowOnce,
    request.options,
  );

  if (grantKey != null && grants.holds(chat, grantKey)) {
    log.info(agent, 'permission allowed by this chat: $grantKey');
    answer(allow);
    return;
  }

  final what = grantKey ?? request.summary;
  switch (decideHermesPermission(
    toolKind: agentPermissionToolKind(request.kind),
    options: request.options,
    mode: approval,
  )) {
    case HermesAllow(:final optionId):
      log.info(agent, 'permission allowed (${approval.name}): $what');
      answer(optionId);
    case HermesRefuse(:final optionId):
      log.warn(agent, 'permission refused (${approval.name}): $what');
      answer(optionId);
    case HermesAskUser():
      ref.read(agentPermissionsProvider.notifier).ask(chat, request, (
        optionId,
      ) {
        if (grantKey != null && optionId == kAllowForChatOption) {
          grants.grant(chat, grantKey);
        }
        log.info(agent, 'permission answered ${optionId ?? 'no'}: $what');
        answer(optionId);
      });
  }
}
