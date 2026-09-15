import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import 'chat_sessions_controller.dart';

/// How much the assistant may do without asking **in the chat that is open**.
///
/// This used to be one app-wide setting, which made the composer's pill a lie
/// the moment you switched chats: turning on full access to let the agent
/// rebuild a project left the next chat — about something else entirely —
/// running without asking, with the same pill on screen either way. The mode is
/// a decision about one piece of work, so it belongs to the conversation.
///
/// A chat that has never been told follows [ChatPrefs.approval], the standing
/// choice; see [ChatSessionsController.setApproval] for which of the two a pick
/// writes to.
final chatApprovalModeProvider = Provider<AgentApprovalMode>(
  (ref) =>
      ref.watch(chatSessionsProvider.select((s) => s.active?.approval)) ??
      ref.watch(chatPrefsProvider).approval,
);

/// What each mode is called, everywhere it is named.
///
/// In logic rather than beside the picker that used to own it, because the
/// composer is no longer the only thing that shows these: a paired phone is
/// sent the same list, and two places wording "Full access" differently would
/// be two apps describing the same power in different words (§5).
/// The name of a mode, as the user reads it in the composer.
String approvalLabel(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly => 'Read only',
  AgentApprovalMode.plan => 'Plan first',
  AgentApprovalMode.ask => 'Ask before acting',
  AgentApprovalMode.full => 'Full access',
};
