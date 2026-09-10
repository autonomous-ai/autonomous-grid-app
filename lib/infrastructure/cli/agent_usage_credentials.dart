/// Where the agent CLIs keep the tokens their own usage endpoints want.
///
/// This app **reads** them; it never writes one and never refreshes one. One
/// sign-in per machine, owned by the CLI that made it — the same rule Grid
/// follows with `~/.grid/credentials.toml`. A second copy here would be a
/// second thing to expire and to disagree about.
///
/// ⚠️ **Nothing in this file may be logged.** Every value it returns is a
/// bearer token; the CLI transcript exists precisely so secrets stay out of
/// argv, and a log line here would undo that. Callers get the token and nothing
/// else — no wrapper that carries it into an error message.
library;

import 'dart:convert';
import 'dart:io';

/// A token, and when it stops working.
class AgentToken {
  const AgentToken({required this.accessToken, this.expiresAt, this.accountId});

  final String accessToken;

  /// When the store said it expires. Null means unknown, which is treated as
  /// "try it" rather than "assume dead" — the endpoint answering 401 is a
  /// better authority than a clock we may be reading wrong.
  final DateTime? expiresAt;

  /// Codex scopes its reading to an account; Claude does not send one.
  final String? accountId;

  bool get isExpired {
    final at = expiresAt;
    return at != null && at.isBefore(DateTime.now());
  }
}

/// Reads the tokens the usage endpoints need, from wherever each CLI put them.
class AgentUsageCredentials {
  const AgentUsageCredentials({this.home, this.runProcess});

  /// Overridden by tests. Null means this machine's real home.
  final String? home;

  /// Overridden by tests, so nothing shells out to the real `security`.
  final Future<ProcessResult> Function(String, List<String>)? runProcess;

  String? get _home => home ?? Platform.environment['HOME'];

  /// Claude Code's OAuth token.
  ///
  /// macOS keeps it in the login Keychain and Linux in a file, so both are
  /// tried in that order — and the file is tried on macOS too, because a
  /// Keychain that will not answer (a locked login chain, a launch with no
  /// authorization) is a state, not the end of the road.
  Future<AgentToken?> claude() async =>
      _parseClaude(await _readKeychain()) ??
      _parseClaude(_readFile('.claude/.credentials.json'));

  /// Codex's OAuth token, written by `codex login`.
  Future<AgentToken?> codex() async {
    final tokens = _decode(_readFile('.codex/auth.json'))?['tokens'];
    if (tokens is! Map) return null;
    final access = tokens['access_token'];
    if (access is! String || access.isEmpty) return null;
    final id = tokens['account_id'];
    return AgentToken(
      accessToken: access,
      accountId: id is String && id.isNotEmpty ? id : null,
    );
  }

  AgentToken? _parseClaude(String? raw) {
    final oauth = _decode(raw)?['claudeAiOauth'];
    if (oauth is! Map) return null;
    final access = oauth['accessToken'];
    if (access is! String || access.isEmpty) return null;
    final expires = oauth['expiresAt'];
    return AgentToken(
      accessToken: access,
      expiresAt: expires is num
          ? DateTime.fromMillisecondsSinceEpoch(expires.round())
          : null,
    );
  }

  /// The login Keychain entry `claude` writes on macOS. Absent, locked or
  /// refused all read the same way here — null, and the file is tried next.
  Future<String?> _readKeychain() async {
    if (!Platform.isMacOS) return null;
    final run = runProcess ?? Process.run;
    try {
      final result = await run('security', [
        'find-generic-password',
        '-s',
        'Claude Code-credentials',
        '-w',
      ]);
      if (result.exitCode != 0) return null;
      final out = '${result.stdout}'.trim();
      return out.isEmpty ? null : out;
    } on ProcessException {
      return null;
    }
  }

  String? _readFile(String relative) {
    final home = _home;
    if (home == null || home.isEmpty) return null;
    final file = File('$home/$relative');
    if (!file.existsSync()) return null;
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  Map<Object?, Object?>? _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
