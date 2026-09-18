/// What a paired phone may change about a chat, and what it may change it to.
///
/// **The computer works out the choices; the phone renders them.** Which models
/// this grid serves, which agents are installed, and which of those pairs can
/// actually answer ([agentSupportsModel]) are rules that live here and have
/// moved more than once. A phone that re-derived them would be a second copy
/// drifting out of step with the composer people use every day — and the first
/// symptom would be a pick that silently never answers.
///
/// So every option arrives ready to draw: an id to send back, a label already
/// worded the way the composer words it, and whether it can be picked at all.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_model_support.dart';
import '../../agents/logic/agent_status.dart';
import '../../chat/logic/chat_approval.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/conversation.dart';
import '../../chat/logic/grid_model_catalog.dart';
import '../../playground/logic/grid_served_models.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';

/// The one mode a phone is never allowed to switch on.
///
/// `full` is "commands run and files change without asking". Everything else
/// here is a preference; this one is unattended execution, and the device
/// asking for it is the one somebody can leave in a taxi. A phone can still
/// *use* a chat already set to it at the computer — it simply cannot be the
/// thing that turns it on.
const AgentApprovalMode kApprovalPhoneMayNotSet = AgentApprovalMode.full;

/// Whether a phone is allowed to put a chat into [mode].
///
/// Pure, and separate from the setter, because it is the single rule in this
/// file worth being able to state and test on its own: everything else here is
/// a list being copied, and this is the one place a phone is told no.
bool phoneMaySetApproval(AgentApprovalMode mode) =>
    mode != kApprovalPhoneMayNotSet;

/// Everything the phone's composer needs to draw its pickers for one chat.
///
/// Asynchronous for one reason, and it is the reason the model pill first
/// shipped showing a single row called "subscription": the grid's list is a
/// *request*, not a value lying around. Read on the spot from a window that
/// need not even be on the Chat tab, [playgroundModelsProvider] hands back the
/// empty list it starts from — and what survives `chatModelOptions` on an empty
/// list is the subscription row, which is the one option that is not a model
/// this grid serves. [gridServedModels] waits for the answer and keeps the
/// provider alive across the wait; the Telegram bot's `/model` had the same bug
/// first, which is why that function is shared rather than copied.
Future<Map<String, Object?>> phoneChatOptions(Ref ref, String chatId) async {
  final chat = _find(ref, chatId);
  final served = await gridServedModels(ref);
  final models = chatModelOptions(
    served,
    agentInstalled: ref.read(anyAgentInstalledProvider),
  );
  final currentModel = chat?.model ?? ref.read(chatPrefsProvider).model ?? '';
  final currentAgent = chat?.agent;
  final approval = chat?.approval ?? ref.read(chatPrefsProvider).approval;
  return {
    'model': {
      'selected': currentModel,
      'options': [
        // The name a person picked it by, not the id it is sent as: the pill
        // shows the label while `chats.set` carries the id, so a routed row
        // reads as "Fastest" and travels as the routing id it really is.
        //
        // Text only — this composer sends text, and a media model offered here
        // would be a pick that answers nothing.
        for (final option in models)
          if (option.modality == PlaygroundModality.text)
            {'id': option.id, 'label': option.label},
      ],
    },
    'agent': {
      'selected': currentAgent ?? '',
      'options': [
        for (final tool in AgentTool.values)
          if (ref.read(agentInstalledProvider(tool)))
            {
              'id': tool.id,
              'label': tool.name,
              // Sent rather than left for the phone to work out: the pairing
              // rules are a switch over agent *and* model id that has changed
              // as agents changed, and a phone shipping the old copy would
              // offer a combination that answers nothing.
              'enabled': agentSupportsModel(tool, currentModel),
              'why': agentSupportsModel(tool, currentModel)
                  ? ''
                  : "${tool.name} can't answer with $currentModel.",
            },
      ],
    },
    'approval': {
      'selected': approval.name,
      'options': [
        for (final mode in AgentApprovalMode.values)
          {
            'id': mode.name,
            'label': approvalLabel(mode),
            'enabled': phoneMaySetApproval(mode),
            'why': !phoneMaySetApproval(mode)
                ? 'Only the computer can turn this on.'
                : '',
          },
      ],
    },
  };
}

/// Changes one thing about a chat, and says what went wrong when it cannot.
///
/// Returns null on success or **a sentence to show the person**, for the same
/// reason [startPhoneTurn] does: every refusal here is something they can go
/// and fix, and a generic failure would hide which.
Future<String?> setPhoneChatOption(
  Ref ref, {
  required String chatId,
  required String field,
  required String value,
}) async {
  final sessions = ref.read(chatSessionsProvider.notifier);
  if (_find(ref, chatId) == null) {
    return 'That chat is not on this computer any more.';
  }
  return switch (field) {
    'model' => await _setModel(ref, sessions, chatId, value),
    'agent' => _setAgent(ref, sessions, chatId, value),
    'approval' => _setApproval(ref, sessions, chatId, value),
    'archived' => _setArchived(ref, sessions, chatId, value),
    _ => 'That is not something this phone can change.',
  };
}

Future<String?> _setModel(
  Ref ref,
  ChatSessionsController sessions,
  String chatId,
  String model,
) async {
  // Waited for, like the list the phone was offered. Validating against the
  // read-on-the-spot value would refuse every model on a grid whose answer has
  // not landed yet — including the one this phone was just shown.
  final served = chatModelOptions(
    await gridServedModels(ref),
    agentInstalled: ref.read(anyAgentInstalledProvider),
  );
  // Checked against the list the phone was given rather than accepted as typed:
  // a model this grid does not serve is a turn that fails at the relay with a
  // message about providers, long after the pick that caused it.
  if (!served.any((option) => option.id == model)) {
    return 'This grid is not serving $model right now.';
  }
  sessions.setChatModel(chatId, model);
  return null;
}

String? _setAgent(
  Ref ref,
  ChatSessionsController sessions,
  String chatId,
  String agentId,
) {
  final tool = agentToolById(agentId);
  if (tool == null) return 'This computer does not have that assistant.';
  if (!ref.read(agentInstalledProvider(tool))) {
    return '${tool.name} is not installed on this computer.';
  }
  final chat = _find(ref, chatId);
  final model = chat?.model ?? ref.read(chatPrefsProvider).model ?? '';
  if (model.isNotEmpty && !agentSupportsModel(tool, model)) {
    return "${tool.name} can't answer with $model.";
  }
  sessions.setChatAgent(chatId, agentId);
  return null;
}

String? _setApproval(
  Ref ref,
  ChatSessionsController sessions,
  String chatId,
  String value,
) {
  final mode = AgentApprovalMode.values
      .where((candidate) => candidate.name == value)
      .firstOrNull;
  if (mode == null) return 'That is not one of the access settings.';
  if (!phoneMaySetApproval(mode)) {
    return 'Full access has to be turned on at the computer.';
  }
  sessions.setChatApproval(chatId, mode);
  return null;
}

/// Puts a chat away, or takes it back out.
///
/// Behind the same switch as every other change, and not because archiving is
/// dangerous — it is reversible and destroys nothing. It is behind it because
/// the rule is the one worth having: **a phone reads freely and changes
/// nothing unless somebody said it may.** An exception for the harmless-looking
/// case is how that rule stops being a rule.
String? _setArchived(
  Ref ref,
  ChatSessionsController sessions,
  String chatId,
  String value,
) {
  final away = value == 'true';
  // Mirrors the window's own refusal: archiving a chat mid-answer hides the
  // conversation the reply is about to land in.
  if (away && ref.read(chatSessionsProvider).sendingFor(chatId)) {
    return 'That chat is being answered right now.';
  }
  if (away) {
    sessions.archiveConversation(chatId);
  } else {
    sessions.unarchiveConversation(chatId);
  }
  return null;
}

/// The conversation [id] names, or null when the window does not have it.
Conversation? _find(Ref ref, String id) {
  for (final conversation in ref.read(chatSessionsProvider).conversations) {
    if (conversation.id == id) return conversation;
  }
  return null;
}
