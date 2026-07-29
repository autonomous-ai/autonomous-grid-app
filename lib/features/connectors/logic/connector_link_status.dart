/// Where one connector stands between "never touched" and "the agent can call
/// it", as the backend reports it at `GET {BASE}/device/{id}/connectors`.
///
/// This is the most important contract between the app and the gateway. The
/// five states are the web client's, kept identical on purpose: both clients
/// read the same field from the same endpoint, and a state that means one thing
/// on the web and another here would be a bug nobody could see from either side.
///
/// The load-bearing one is [connecting]. After the OAuth exchange the backend
/// holds a token the *machine* does not have yet; until it arrives the agent
/// cannot call anything. A row that read "Connected" there would promise a tool
/// that isn't wired — the same mistake the backend's `installed` flag invites
/// (see `buildConnectors`).
enum ConnectorLinkStatus {
  /// Nothing here: no account linked, no server configured.
  notInstalled,

  /// Known to the backend but not linked — the row offers Connect. Also where
  /// a connector lands after Disconnect.
  connect,

  /// The token exists at the backend and is on its way to this machine.
  /// Transitional: the row shows a disabled "Connecting…" pill and offers no
  /// Disconnect, and the screen polls until it moves.
  connecting,

  /// The machine has the token and the agent has a server for it.
  connected,

  /// The exchange failed. The row offers Retry and carries the reason.
  connectFailed;

  /// True while the row must keep polling: the backend still owes an answer.
  bool get isSettling => this == ConnectorLinkStatus.connecting;

  /// True when the connector belongs in the screen's "Connected" bucket —
  /// [connecting] included, because it is on its way there and moving it
  /// between buckets mid-flight would make the list jump under the cursor.
  bool get isLinked =>
      this == ConnectorLinkStatus.connected ||
      this == ConnectorLinkStatus.connecting;
}

/// Read the backend's `status` string.
///
/// Deliberately forgiving in one direction only: an unknown value reads as
/// [ConnectorLinkStatus.connect] — "there is something here to link" — rather
/// than as connected. A state the backend grows later must never make the
/// screen claim a working tool it has never heard of.
///
/// Null and empty read as [ConnectorLinkStatus.notInstalled], matching a row
/// the backend never mentions.
ConnectorLinkStatus parseConnectorLinkStatus(Object? raw) {
  if (raw is! String || raw.isEmpty) return ConnectorLinkStatus.notInstalled;
  return switch (raw) {
    'not_installed' => ConnectorLinkStatus.notInstalled,
    'connect' => ConnectorLinkStatus.connect,
    'connecting' => ConnectorLinkStatus.connecting,
    'connected' => ConnectorLinkStatus.connected,
    'connect_failed' => ConnectorLinkStatus.connectFailed,
    _ => ConnectorLinkStatus.connect,
  };
}
