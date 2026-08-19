import '../../../infrastructure/cli/hermes_cron_service.dart';
import '../../chat/logic/conversation.dart';
import 'task_conversation_id.dart';

/// Where a scheduled task's results are put when a run finishes.
///
/// Until 2026-08-19 there was one answer — a chat of the task's own — and it is
/// the wrong one twice over: a task set up inside a project put its results
/// outside it, and a task the user asked for *in a chat* answered somewhere
/// else entirely, which reads as the task having quietly not run.
sealed class TaskDestination {
  const TaskDestination();
}

/// The task's own chat ([taskConversationId]) — one thread per task, which is
/// right for a standing digest nobody asked for in a conversation.
final class TaskOwnChat extends TaskDestination {
  const TaskOwnChat();
}

/// An existing conversation: the one the task was set up in.
final class TaskChatDestination extends TaskDestination {
  const TaskChatDestination(this.chatId);

  final String chatId;
}

/// A project: the task's own chat, filed under that project.
///
/// Still its own chat rather than one of the project's: a task that fires every
/// morning would otherwise interleave its results with whatever the user was
/// doing in there, and the link is what puts it in the project's list.
final class TaskProjectDestination extends TaskDestination {
  const TaskProjectDestination(this.projectId);

  final String projectId;
}

/// The prefix on every destination this app writes into Hermes's `deliver`
/// field.
///
/// **Hermes does not know these targets and will not try to reach them.** It
/// reads anything with a colon as `platform:chat_id`, fails to find a platform
/// called `grid`, and records a delivery error in its own store — while still
/// writing the result file, which is the part the app reads (measured
/// 2026-08-19). That error is Hermes describing something it was never asked to
/// do; the app neither reads nor shows it.
///
/// TODO(BE): the honest fix is a delivery target Hermes ignores by design. This
/// rides in `deliver` because it is the only field both the app *and* an agent
/// running `hermes cron create` in a terminal can write, and one field beats a
/// second store the agent could never reach.
const String kGridDeliverPrefix = 'grid:';

/// How many conversations the destination picker offers.
///
/// A cap, because the list is there to find "the chat I was just in" — every
/// chat the user has ever had turns one decision into a search.
const int kTaskDestinationChats = 12;

/// The `--deliver` value for [destination]. [kDeliverLocal] — Hermes's own
/// "write the result to a file" — is what every one of them still rides on.
String taskDeliverValue(TaskDestination destination) => switch (destination) {
  TaskOwnChat() => kDeliverLocal,
  TaskChatDestination(:final chatId) => '${kGridDeliverPrefix}chat:$chatId',
  TaskProjectDestination(:final projectId) =>
    '${kGridDeliverPrefix}project:$projectId',
};

/// The destination [raw] names, defaulting to [TaskOwnChat].
///
/// Lenient on purpose: `deliver` is a free-text field in somebody else's store,
/// and a value this app doesn't recognise — an older build's, a hand-edited
/// one, `telegram` — means "not one of ours", which is the task's own chat. A
/// throw here would take down the sweep that delivers every other task.
TaskDestination parseTaskDeliver(String? raw) {
  final value = raw?.trim() ?? '';
  if (!value.startsWith(kGridDeliverPrefix)) return const TaskOwnChat();
  final rest = value.substring(kGridDeliverPrefix.length);
  final split = rest.indexOf(':');
  if (split <= 0 || split == rest.length - 1) return const TaskOwnChat();
  final id = rest.substring(split + 1);
  return switch (rest.substring(0, split)) {
    'chat' => TaskChatDestination(id),
    'project' => TaskProjectDestination(id),
    _ => const TaskOwnChat(),
  };
}

/// The conversation [destination] delivers into, for a task with [jobId].
///
/// [chats] is what the app has: a destination chat the user has since deleted
/// falls back to the task's own, so a result is never dropped for want of a
/// thread to put it in.
String taskDeliveryChatId(
  TaskDestination destination,
  String jobId,
  Iterable<Conversation> chats,
) => switch (destination) {
  TaskChatDestination(:final chatId)
      when chats.any((chat) => chat.id == chatId) =>
    chatId,
  _ => taskConversationId(jobId),
};

/// The project [destination] files the task under, or null when it names none.
String? taskDestinationProjectId(TaskDestination destination) =>
    switch (destination) {
      TaskProjectDestination(:final projectId) => projectId,
      _ => null,
    };
