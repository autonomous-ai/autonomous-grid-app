// The half of [MobileChatRpc] that changes something.
//
// A `part` rather than a second class: it is one API about one chat, with one
// constructor and one set of collaborators, and splitting the object would put
// half of a phone's requests behind a different door for no reason a caller
// benefits from. Split as a *file* because the reading half and the writing
// half are read for different reasons — and because every method below is
// behind the same switch, which is easier to audit when they sit together.
part of 'mobile_chat_rpc.dart';

extension MobileChatWrites on MobileChatRpc {
  /// What the phone's composer may offer for a chat.
  ///
  /// A read, so it is not behind the switch: knowing which models this grid
  /// serves tells a phone nothing it cannot already see in the chat list, and a
  /// composer that cannot draw its own pickers until somebody grants it
  /// permission is a screen that looks broken rather than locked.
  MobileRpcResponse options(MobileRpcRequest request) {
    final read = readOptions;
    if (read == null) {
      return MobileRpcFailed(
        request.id,
        code: 'unavailable',
        message: 'Grid on the computer cannot answer that right now.',
      );
    }
    final id = request.params['id'];
    if (id is! String || id.isEmpty) {
      return MobileRpcFailed(
        request.id,
        code: 'bad_request',
        message: 'Which chat?',
      );
    }
    return MobileRpcOk(request.id, read(id));
  }

  /// Changes a chat's model, assistant or access.
  ///
  /// Behind the same switch as sending, and deliberately so: these decide what
  /// the next turn is allowed to do and who carries it out. A phone that could
  /// set them without being trusted to send would simply be arranging the
  /// conditions for somebody else's next message.
  Future<MobileRpcResponse> set(
    MobileRpcRequest request,
    Future<bool> Function()? mayAct,
  ) async {
    final change = setOption;
    if (change == null) return _noApp(request);
    if (mayAct == null || !await mayAct()) {
      return _notAllowed(request, 'change them');
    }
    final id = request.params['id'];
    final field = request.params['field'];
    final value = request.params['value'];
    if (id is! String || field is! String || value is! String) {
      return MobileRpcFailed(
        request.id,
        code: 'bad_request',
        message: 'That change is missing something.',
      );
    }
    final refused = change(id, field, value);
    return refused == null
        ? MobileRpcOk(request.id, {'ok': true})
        : MobileRpcFailed(request.id, code: 'unavailable', message: refused);
  }

  /// Starts a chat with its first message in it.
  Future<MobileRpcResponse> create(
    MobileRpcRequest request,
    Future<bool> Function()? mayAct,
  ) async {
    final start = createChat;
    if (start == null) return _noApp(request);
    if (mayAct == null || !await mayAct()) {
      return _notAllowed(request, 'start new ones');
    }
    final text = request.params['text'];
    if (text is! String || text.trim().isEmpty) {
      return MobileRpcFailed(
        request.id,
        code: 'bad_request',
        message: 'A new chat needs something to say.',
      );
    }
    final project = request.params['projectId'];
    final started = await start(
      text.trim(),
      project is String && project.isNotEmpty ? project : null,
    );
    final id = started.id;
    if (id == null) {
      return MobileRpcFailed(
        request.id,
        code: 'unavailable',
        message: started.problem ?? 'The chat could not be started.',
      );
    }
    return MobileRpcOk(request.id, {'id': id});
  }

  MobileRpcFailed _noApp(MobileRpcRequest request) => MobileRpcFailed(
    request.id,
    code: 'unavailable',
    message: 'Grid on the computer cannot take messages right now.',
  );

  /// The refusal a phone gets when the switch is off.
  ///
  /// [cannot] names the thing it just tried, because "you cannot do that" over
  /// three different buttons is three chances to think the app is broken.
  MobileRpcFailed _notAllowed(MobileRpcRequest request, String cannot) =>
      MobileRpcFailed(
        request.id,
        code: 'forbidden',
        message:
            'This phone can read your chats but not $cannot. Turn on "Let '
            'this phone send messages" in Grid on your computer.',
      );

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
    if (start == null) return _noApp(request);
    if (mayAct == null || !await mayAct()) return _notAllowed(request, 'send');
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
}
