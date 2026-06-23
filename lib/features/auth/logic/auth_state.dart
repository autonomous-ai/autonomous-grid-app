/// States of the device-login flow.
sealed class AuthState {
  const AuthState();
}

/// Nothing started yet.
class AuthIdle extends AuthState {
  const AuthIdle();
}

/// `grid auth login` spawned; waiting for the URL + code to appear.
class AuthStarting extends AuthState {
  const AuthStarting();
}

/// Showing the URL + code; the CLI is polling the control plane for approval.
class AuthAwaitingApproval extends AuthState {
  const AuthAwaitingApproval({required this.url, required this.userCode});
  final String url;
  final String userCode;
}

/// Login succeeded (CLI exited 0); credentials were written to `~/.grid`.
class AuthSuccess extends AuthState {
  const AuthSuccess();
}

/// Login failed; [message] is the CLI's stderr (or a fallback).
class AuthFailure extends AuthState {
  const AuthFailure(this.message);
  final String message;
}
