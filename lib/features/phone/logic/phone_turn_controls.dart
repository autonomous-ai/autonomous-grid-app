/// A chat's turn in flight, as a paired phone sees and steers it.
///
/// Reads the same three places the window's own chat reads — the send phase,
/// the agent's live run, the open permission question — and acts through the
/// same two calls its Stop button and its permission card make. The phone is
/// one more surface on the same turn, the way Telegram and the Panel are, not a
/// second copy of it: whichever side answers a question first wins, and the
/// other's card closes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_pairing/grid_pairing.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/pairing_host/mobile_turn_controls.dart';
import '../../agents/logic/agent_permissions.dart';
import '../../agents/logic/agent_providers.dart';
import '../../chat/logic/chat_sessions_controller.dart';

/// The running app's side of [MobileTurnControls].
class PhoneTurnControls implements MobileTurnControls {
  const PhoneTurnControls(this._ref);

  final Ref _ref;

  @override
  bool isBusy(String chatId) =>
      _ref.read(chatSessionsProvider).sendingFor(chatId);

  /// **This is why the phone showed a spinner and nothing else while the
  /// computer worked.** A turn is not written to disk until it finishes, and
  /// the phone reads the transcript from disk — the window was not reading a
  /// file: it holds the reply so far in [SendStreaming].
  @override
  String streaming(String chatId) =>
      switch (_ref.read(chatSessionsProvider).phaseFor(chatId)) {
        SendStreaming(:final text) => text,
        // Started but no token yet. `busy` already says so, and an empty
        // bubble says less than the phone's working line.
        _ => '',
      };

  @override
  ({List<MobileStep> steps, int count}) steps(
    String chatId, {
    required int newest,
  }) {
    final all = _ref.read(agentRunsProvider)[chatId]?.steps ?? const [];
    return (
      steps: [for (final step in newestOf(all, newest)) mobileStepOf(step)],
      count: all.length,
    );
  }

  @override
  MobilePermission? permission(String chatId) {
    final asked = _ref.read(agentPermissionsProvider)[chatId];
    return asked == null ? null : mobilePermissionOf(asked);
  }

  @override
  bool stop(String chatId) {
    if (!isBusy(chatId)) return false;
    _ref.read(chatSessionsProvider.notifier).stopChat(chatId);
    return true;
  }

  @override
  String? answer(
    String chatId,
    String questionId,
    MobilePermissionChoice choice,
  ) {
    final asked = _ref.read(agentPermissionsProvider)[chatId];
    if (asked == null || '${asked.id}' != questionId) {
      return 'That question has already closed.';
    }
    if (choice == MobilePermissionChoice.allowForChat &&
        !asked.canAllowForChat) {
      return "The assistant didn't offer that for this question.";
    }
    _ref
        .read(agentPermissionsProvider.notifier)
        .answer(chatId, agentChoiceOf(choice));
    return null;
  }
}

/// [step] as the phone is told about it — the label and the outcome, never
/// what the tool read or returned.
MobileStep mobileStepOf(AgentActivity step) => MobileStep(
  id: step.id,
  kind: switch (step.kind) {
    AgentActivityKind.command => MobileStepKind.command,
    AgentActivityKind.web => MobileStepKind.web,
    AgentActivityKind.tool => MobileStepKind.tool,
    AgentActivityKind.thinking => MobileStepKind.thinking,
  },
  label: step.label,
  status: switch (step.status) {
    AgentActivityStatus.running => MobileStepStatus.running,
    AgentActivityStatus.done => MobileStepStatus.done,
    AgentActivityStatus.failed => MobileStepStatus.failed,
    AgentActivityStatus.unknown => MobileStepStatus.unknown,
  },
  tool: step.tool,
  nested: step.isNested,
);

/// [asked] as the phone's card shows it.
///
/// The file's current contents stay behind: the card on the computer shows a
/// diff, and a phone is shown the file and what it would become — enough to
/// judge, without shipping a whole file to answer yes or no.
MobilePermission mobilePermissionOf(AgentPermission asked) => MobilePermission(
  id: '${asked.id}',
  kind: switch (asked.kind) {
    AgentPermissionKind.command => MobilePermissionKind.command,
    AgentPermissionKind.edit => MobilePermissionKind.edit,
    AgentPermissionKind.other => MobilePermissionKind.other,
  },
  summary: asked.summary,
  detail: asked.kind == AgentPermissionKind.edit ? asked.path : asked.command,
  preview: asked.kind == AgentPermissionKind.edit ? asked.newText : null,
  canAllowForChat: asked.canAllowForChat,
);

/// The phone's answer, as the permission controller takes it.
AgentPermissionChoice agentChoiceOf(MobilePermissionChoice choice) =>
    switch (choice) {
      MobilePermissionChoice.allowOnce => AgentPermissionChoice.allowOnce,
      MobilePermissionChoice.allowForChat => AgentPermissionChoice.allowForChat,
      MobilePermissionChoice.refuse => AgentPermissionChoice.refuse,
    };
