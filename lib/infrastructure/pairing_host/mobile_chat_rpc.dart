/// The chat and project methods a paired phone may call.
///
/// Split out of [MobileRpcService] because they are a different job: that class
/// decides *whether* a call is allowed and answers for the computer itself,
/// while these four answer for the Chat tab. They also hold the one method that
/// makes this computer act, which is worth being able to read in one screen.
///
/// Flutter-free like the rest of this folder — [sendToChat] is the seam where
/// the app reaches in, and where `tool/` simply does not.
library;

import 'package:grid_pairing/grid_pairing.dart';

import 'mobile_chat_reader.dart';

/// Answers the phone about chats and projects.
class MobileChatRpc {
  MobileChatRpc({
    List<ChatHeader> Function()? readChats,
    List<ProjectSummary> Function()? readProjects,
    ChatPage? Function(String id, {int? limit, int? offset})? readChat,
    this.sendToChat,
    this.chatIsBusy,
  }) : _readChats = readChats ?? readChatHeaders,
       _readProjects = readProjects ?? readProjectSummaries,
       _readChat = readChat ?? readChatPage;

  /// Puts a turn into a chat, or null where nothing can — `tool/` runs the host
  /// without the app around it, and a host with no Chat tab behind it must
  /// answer `unavailable` rather than pretend.
  ///
  /// Returns null once the turn is on its way, or **a sentence to show the
  /// person** when it could not start. A returned string rather than a thrown
  /// error because these are refusals somebody can act on — no grid signed in,
  /// no model running — and the catch-all below deliberately replaces exception
  /// text with a generic line, which would hide exactly the part that helps.
  final Future<String?> Function(String chatId, String text)? sendToChat;

  /// Whether an answer is still being written in a chat, so the phone knows
  /// whether to keep looking.
  final bool Function(String chatId)? chatIsBusy;

  final List<ChatHeader> Function() _readChats;
  final List<ProjectSummary> Function() _readProjects;
  final ChatPage? Function(String id, {int? limit, int? offset}) _readChat;

  /// Every conversation's header.
  Map<String, Object?> list() => {
    'chats': [
      for (final chat in _readChats())
        {
          'id': chat.id,
          'title': chat.title,
          'model': chat.model,
          'agent': chat.agent,
          'projectId': chat.projectId,
          'updatedAt': chat.updatedAt,
          'archived': chat.archived,
        },
    ],
  };

  /// Every project, without its path.
  Map<String, Object?> projects() => {
    'projects': [
      for (final project in _readProjects())
        {
          'id': project.id,
          'name': project.name,
          'model': project.model,
          'agent': project.agent,
        },
    ],
  };

  /// One page of a transcript. `offset` and `limit` page *backwards*: the
  /// default page ends at the newest turn, and the phone asks for a smaller
  /// offset to walk into the history.
  MobileRpcResponse page(MobileRpcRequest request) {
    final id = request.params['id'];
    if (id is! String || id.isEmpty) {
      return MobileRpcFailed(
        request.id,
        code: 'bad_request',
        message: 'Which chat?',
      );
    }
    final page = _readChat(
      id,
      limit: _asInt(request.params['limit']),
      offset: _asInt(request.params['offset']),
    );
    // Not an empty transcript: a phone told a chat is empty would offer to send
    // the first message into a conversation this computer does not have.
    if (page == null) return _gone(request);
    return MobileRpcOk(request.id, {
      'id': id,
      'total': page.total,
      'offset': page.offset,
      // Whether an answer is still being written. The phone polls this page
      // while a turn runs, and without it there is no moment it can stop.
      'busy': chatIsBusy?.call(id) ?? false,
      'messages': [
        for (final line in page.lines) {'role': line.role, 'text': line.text},
      ],
    });
  }

  /// Puts one message from the phone into a chat on this computer.
  ///
  /// Three refusals before anything runs, and they are deliberately different
  /// answers: the computer cannot do this at all, this phone is not allowed to,
  /// or that chat is not here. A single "no" would leave the person guessing
  /// which of the three to go and fix.
  Future<MobileRpcResponse> send(
    MobileRpcRequest request,
    Future<bool> Function()? mayAct,
  ) async {
    final start = sendToChat;
    if (start == null) {
      return MobileRpcFailed(
        request.id,
        code: 'unavailable',
        message: 'Grid on the computer cannot take messages right now.',
      );
    }
    if (mayAct == null || !await mayAct()) {
      return MobileRpcFailed(
        request.id,
        code: 'forbidden',
        message:
            'This phone can read your chats but not send. Turn on "Let this '
            'phone send messages" in Grid on your computer.',
      );
    }
    final id = request.params['id'];
    final text = request.params['text'];
    if (id is! String || id.isEmpty || text is! String || text.trim().isEmpty) {
      return MobileRpcFailed(
        request.id,
        code: 'bad_request',
        message: 'A message needs a chat and something to say.',
      );
    }
    // Checked here rather than left to the send: a chat that is gone would
    // otherwise be created by the act of answering it, and the phone would have
    // started a conversation it thought it was continuing.
    if (_readChat(id, limit: 1) == null) return _gone(request);
    final refused = await start(id, text.trim());
    if (refused != null) {
      return MobileRpcFailed(request.id, code: 'unavailable', message: refused);
    }
    return MobileRpcOk(request.id, {'accepted': true});
  }

  MobileRpcFailed _gone(MobileRpcRequest request) => MobileRpcFailed(
    request.id,
    code: 'not_found',
    message: 'That chat is not on this computer any more.',
  );
}

/// [value] as a whole number, or null when it is anything else.
///
/// JSON numbers arrive as `int` or `double` depending on how the phone wrote
/// them, and a paging cursor that silently reads as null sends the first page
/// forever.
int? _asInt(Object? value) => switch (value) {
  final int number => number,
  final double number => number.toInt(),
  _ => null,
};
