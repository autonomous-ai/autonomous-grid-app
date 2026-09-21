/// What this computer will accept on an incoming connection, and for how long.
///
/// A relay used to hold these. With the cell in-process there is no relay to
/// hold them, so they are held here — and the rules stay exactly the ones the
/// cell enforced, because a phone cannot tell the difference and must not have
/// to.
///
/// Two kinds, and the difference is the whole point:
///
/// - An **invite** is one connection's worth of authority, ten minutes long. It
///   is a code on a screen and nobody has proved anything yet, so it is spent
///   the moment it is used.
/// - A **resume** is reusable and long-lived, and is only ever handed to a
///   phone *inside* the sealed channel it already authenticated on. That is
///   what makes the longer life reasonable.
///
/// ⚠️ Neither is the device's own token. The credential that opens a
/// connection travels in the clear to whoever terminates TLS — see
/// `PairingOffer`: *"The end-to-end layer protects the conversation, never the
/// credential that starts it."* Spending a phone's long-lived identity there
/// would hand it to the tunnel on every reconnect.
library;

/// How long a pairing code is good for. It is read off a screen and typed into
/// a phone standing next to it; longer is authority nobody is watching.
const Duration kInviteLife = Duration(minutes: 10);

/// How long a resume credential lasts. Long, because its whole job is to spare
/// somebody re-pairing a phone they already paired, and it never leaves a
/// sealed channel.
const Duration kResumeLife = Duration(days: 30);

/// One credential, and what it opens.
typedef CellCredential = ({String deviceId, int expiresAtMs, bool singleUse});

/// The credentials this computer is currently willing to accept.
///
/// Pure: no clock of its own and no sockets. Every method takes the time it
/// should judge by, so expiry is tested rather than waited out.
class CellCredentials {
  final Map<String, CellCredential> _byToken = {};

  /// Accept [token] for [deviceId] until [nowMs] + [life].
  void mint(
    String token, {
    required String deviceId,
    required Duration life,
    required bool singleUse,
    required int nowMs,
  }) => _byToken[token] = (
    deviceId: deviceId,
    expiresAtMs: nowMs + life.inMilliseconds,
    singleUse: singleUse,
  );

  /// The device [token] admits, or null when it admits nobody.
  ///
  /// Spends a single-use credential, so an invite replayed — by whoever was
  /// looking over a shoulder, or by whoever a screenshot reached — opens
  /// nothing the second time.
  String? spend(String token, {required int nowMs}) {
    final credential = _byToken[token];
    if (credential == null) return null;
    if (nowMs >= credential.expiresAtMs) {
      _byToken.remove(token);
      return null;
    }
    if (credential.singleUse) _byToken.remove(token);
    return credential.deviceId;
  }

  /// Drop everything [deviceId] could have connected with.
  ///
  /// Revoking a phone at the computer has to reach the credentials it is
  /// holding, or a revoked device keeps its way back in until the token ages
  /// out — which for a resume is a month.
  void revokeFor(String deviceId) =>
      _byToken.removeWhere((_, value) => value.deviceId == deviceId);

  /// Forget what has aged out. Called when credentials are minted, so a long
  /// session does not grow a map of dead tokens.
  void sweep({required int nowMs}) =>
      _byToken.removeWhere((_, value) => nowMs >= value.expiresAtMs);

  /// How many are live. For tests and for the activity log; never for a phone.
  int get length => _byToken.length;
}
