import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The conversation the chat screen is showing, so anything an agent raises
/// speaks for that chat alone.
///
/// Published by the chat screen rather than derived here: which conversation is
/// open is the chat feature's fact, and the agent feature only needs to be told
/// — deriving it would point this feature at the other's controller. Read by
/// the undo bar and by the question card, both of which must go quiet the
/// moment the user looks somewhere else: an agent keeps working after they move
/// on, and another chat must neither claim its changes nor answer its
/// questions. Null before any chat is on screen.
final agentChatScopeProvider =
    NotifierProvider<AgentChatScopeController, String?>(
      AgentChatScopeController.new,
    );

class AgentChatScopeController extends Notifier<String?> {
  @override
  String? build() => null;

  /// The user is now looking at [chatId] (null when no conversation is open).
  void show(String? chatId) {
    if (state == chatId) return;
    state = chatId;
  }
}
