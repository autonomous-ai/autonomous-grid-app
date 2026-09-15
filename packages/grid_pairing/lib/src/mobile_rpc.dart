/// The request and reply the phone and the desktop exchange inside the sealed
/// channel, and the list of things the phone is allowed to ask for.
///
/// **The allowlist is the security boundary, not the UI.** A phone is a device
/// somebody can pick up; a desktop is where the agents, the keys and the
/// filesystem are. So the phone gets an explicit set of methods and everything
/// else is refused by name, rather than the reverse — a deny-list is a list of
/// the attacks somebody already thought of.
library;

/// Every method a paired phone may call. Anything else is `forbidden`.
///
/// Deliberately tiny. Each entry added here is a new thing a stolen phone can
/// do to the computer, so the question for each one is not "is it useful" but
/// "is it worth that".
const kMobileRpcMethods = <String>{
  'status.get',
  'grids.list',
  'projects.list',
  // Headers only. The transcripts are not in this answer and are not in one
  // reply either: the largest conversation on this machine's history is 9.37 MB
  // and the relay ends a connection that frames more than 8 MB, so reading a
  // chat is paged rather than fetched.
  'chats.list',
  'chats.get',
  // How many turns a chat has and whether one is being written — the two facts
  // a phone needs to know it is out of date. Its own method because it is asked
  // on a timer while a chat is open, and asking `chats.get` for that would
  // re-send the whole page to learn one number.
  'chats.head',
  // The bytes of a picture already attached to a chat this phone can read,
  // asked for a slice at a time. The phone names a *turn*, never a path: the
  // only files reachable this way are ones the computer itself attached.
  'chats.media',
  // The one method here that makes this computer *do* something rather than
  // say what it has already done, and the only one gated by a second check: a
  // per-device switch that is off until somebody turns it on at the computer.
  // A pairing code proves which phone is calling. It cannot prove who is
  // holding it, which is the question this method actually raises.
  'chats.send',
  // What the composer's pickers are drawn from. A read, and the answer is
  // built by the computer rather than derived on the phone: which agent can
  // answer with which model is a rule that has changed as agents changed, and
  // a phone shipping an old copy of it would offer a pick that answers nothing.
  'chats.options',
  // Changing a chat's model, assistant or access. Gated exactly like sending:
  // the rule is read freely, change nothing, unless the switch is on.
  'chats.set',
  // Starting a conversation, message and all. Without it a phone can only
  // continue something that was begun at the computer.
  'chats.create',
  // Putting a picture or a document on the computer, a piece at a time. The
  // only methods here that write bytes rather than text, which is why the store
  // behind them caps the size, the count and the age of what it holds — and why
  // both are behind the same switch as sending.
  'uploads.begin',
  'uploads.chunk',
  // The phone's stand-in for a resume credential. An invite opens exactly one
  // connection and is then spent, so without this a phone that is closed and
  // reopened has to be paired by hand every time. Asking for the next one
  // while the current channel is still up is the cheapest honest fix: it costs
  // no new credential type, and it can only be called by a phone that has
  // already authenticated on this one.
  'pairing.renew',
};

/// One call from the phone.
class MobileRpcRequest {
  const MobileRpcRequest({
    required this.id,
    required this.method,
    this.params = const {},
  });

  /// Correlates the reply. The phone picks it; the desktop only echoes it.
  final String id;

  /// What is being asked for.
  final String method;

  /// Arguments, if the method takes any.
  final Map<String, Object?> params;

  /// This request as JSON, for sealing.
  Map<String, Object?> toJson() => {
    'id': id,
    'method': method,
    if (params.isNotEmpty) 'params': params,
  };

  /// The request [value] describes, or null when it is not one.
  static MobileRpcRequest? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final id = value['id'];
    final method = value['method'];
    if (id is! String || id.isEmpty || method is! String || method.isEmpty) {
      return null;
    }
    final params = value['params'];
    return MobileRpcRequest(
      id: id,
      method: method,
      params: params is Map<String, Object?> ? params : const {},
    );
  }
}

/// What a call came to.
sealed class MobileRpcResponse {
  const MobileRpcResponse(this.id);

  /// The id of the request this answers.
  final String id;

  /// This response as JSON, for sealing.
  Map<String, Object?> toJson();

  /// The response [value] describes, or null when it is not one.
  static MobileRpcResponse? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final id = value['id'];
    if (id is! String) return null;
    if (value['ok'] == true) {
      final result = value['result'];
      return MobileRpcOk(
        id,
        result is Map<String, Object?> ? result : const {},
      );
    }
    final error = value['error'];
    if (error is! Map<String, Object?>) return null;
    final code = error['code'];
    final message = error['message'];
    return code is String && message is String
        ? MobileRpcFailed(id, code: code, message: message)
        : null;
  }
}

/// The call succeeded.
final class MobileRpcOk extends MobileRpcResponse {
  const MobileRpcOk(super.id, this.result);

  /// Whatever the method returns.
  final Map<String, Object?> result;

  @override
  Map<String, Object?> toJson() => {'id': id, 'ok': true, 'result': result};
}

/// The call did not.
final class MobileRpcFailed extends MobileRpcResponse {
  const MobileRpcFailed(super.id, {required this.code, required this.message});

  /// Machine-readable: `forbidden`, `bad_request`, `not_found`,
  /// `unavailable`, `failed`.
  final String code;

  /// Something a person could be shown. Never a raw exception: what the phone
  /// renders should not be this computer's stack trace.
  final String message;

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'ok': false,
    'error': {'code': code, 'message': message},
  };
}
