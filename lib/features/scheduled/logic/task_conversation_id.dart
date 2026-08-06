// The id scheme a scheduled task's chat is named by — nothing else.
//
// Its own file because four places need it and only one of them is the
// delivery sweep: the chat rail, the shell and the unread store all ask "is
// this chat a task's, and which task" without wanting the loop that delivers
// into it. Keeping it here is also what stops the unread store and the sweep
// importing each other.

/// Prefix on a task chat's id, the seam between it and the job id it carries.
const String _kTaskChatPrefix = 'task-';

/// The conversation a task's results land in. One per task, so a daily digest
/// reads as a thread rather than a pile of unrelated chats.
String taskConversationId(String jobId) => '$_kTaskChatPrefix$jobId';

/// The job id behind a task chat's [conversationId], or null when it isn't one
/// — the inverse of [taskConversationId], so opening a chat can find the task to
/// mark read without the chat feature having to know the id scheme.
String? jobIdOfTaskConversation(String? conversationId) {
  if (conversationId == null || !conversationId.startsWith(_kTaskChatPrefix)) {
    return null;
  }
  final jobId = conversationId.substring(_kTaskChatPrefix.length);
  return jobId.isEmpty ? null : jobId;
}
