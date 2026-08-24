import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/agent_homes.dart';
import '../../../../core/grid_paths.dart';
import '../connector_token.dart';

/// Writes the app's connector tokens into the files Hermes reads them from.
///
/// Hermes has its own MCP OAuth machinery (`tools/mcp_oauth.py`) that normally
/// obtains these itself. We're handing it tokens the gateway obtained instead,
/// which works because — verified against that source on 2026-07-30 — the file
/// it reads is plain RFC 6749 §5.1 with one Hermes-specific addition:
///
/// ```json
/// { "access_token": "…", "token_type": "Bearer", "expires_in": 3600,
///   "scope": "…", "refresh_token": "…", "expires_at": 1785000000 }
/// ```
///
/// Three facts from that reading shape this class:
///
/// 1. `expires_at` is Hermes's own field — an absolute instant, because a
///    relative `expires_in` has nothing to measure from after a restart. It
///    rewrites `expires_in` from it on read, so we write both and stay
///    consistent whichever one it happens to trust.
/// 2. Of the three files per server (`<name>.json`, `<name>.client.json`,
///    `<name>.meta.json`) only the tokens file is ours. Client registration
///    comes from `config.yaml` via its `_maybe_preregister_client`, and server
///    metadata it discovers. Writing either of the others would be us guessing
///    at state Hermes owns.
/// 3. A file it can't parse logs a warning and reads as "no token" — it never
///    crashes the agent. That's what makes writing here safe to get wrong.
///
/// Still unverified, and it needs a live run rather than more reading: what the
/// MCP SDK does when *its* refresh attempt fails on a gateway-issued token
/// (refreshing needs a `client_secret` this machine doesn't have). The app's
/// defence doesn't depend on the answer — it rewrites the file before
/// `expires_at`, so the SDK shouldn't reach for a refresh at all.
class HermesTokenProjection {
  HermesTokenProjection({String? home}) : _home = home;

  /// Overridable so tests write into a temp home and never touch the real
  /// `~/.hermes`.
  final String? _home;

  /// Hermes resolves this from `HERMES_HOME`, falling back to `~/.hermes`.
  /// Respect the same override rather than hardcoding, or a user running a
  /// second profile gets tokens written where their agent will never look.
  String get _hermesHome {
    final override = _home ?? Platform.environment['HERMES_HOME'];
    if (override != null && override.isNotEmpty) return override;
    // Grid's own profile, not the user's root — the same home every `hermes`
    // the app spawns is given (see HostEnvironment.hermesEnvironment).
    return AgentHomes.hermesProfile(GridPaths.userHome);
  }

  Directory get tokenDir => Directory('$_hermesHome/mcp-tokens');

  File tokenFile(String serverName) =>
      File('${tokenDir.path}/${safeFileName(serverName)}.json');

  /// Write every token in [tokens], and delete the files named in [removing].
  ///
  /// The deletion half is what makes this a *projection* rather than an append:
  /// disconnecting a connector has to stop the agent using it, and a token file
  /// left behind would keep working until it expired.
  ///
  /// **By name, never by subtraction.** [removing] used to be `owned` — every
  /// connector the config mentioned — and anything not in [tokens] was deleted.
  /// That makes an empty `tokens` mean "delete all of them", which is exactly
  /// what an unreadable store, or one connector's failed refresh, looks like from
  /// in here. It cost two working connectors on 2026-07-30. Only a caller that
  /// deliberately removed something can tell that apart, so only a caller may ask
  /// for a deletion.
  Future<void> project(
    List<ConnectorToken> tokens, {
    Set<String> removing = const {},
  }) async {
    if (tokens.isNotEmpty) await tokenDir.create(recursive: true);

    for (final token in tokens) {
      await tokenFile(token.connector).writeAsString(
        const JsonEncoder.withIndent('  ').convert(_toHermesJson(token)),
        flush: true,
      );
      await _restrict(tokenFile(token.connector));
    }

    final keep = {for (final token in tokens) safeFileName(token.connector)};
    for (final connector in removing) {
      if (keep.contains(safeFileName(connector))) continue;
      final file = tokenFile(connector);
      if (await file.exists()) await file.delete();
    }
  }

  /// Hermes reads both `expires_in` and `expires_at`; write both so it agrees
  /// with itself no matter which path it takes.
  Map<String, dynamic> _toHermesJson(ConnectorToken token) {
    final expiry = token.expiresAt;
    return {
      // Prefer the credential the gateway put in the rendered entry: for a
      // provider with a non-standard header (X-Figma-Token) that header value
      // *is* the credential, and it is the one the server vouched for.
      'access_token': token.mcpEntry?.bearerToken ?? token.accessToken,
      'token_type': token.tokenType,
      if (expiry != null)
        'expires_in': expiry
            .difference(DateTime.now())
            .inSeconds
            .clamp(0, 1 << 31),
      if (expiry != null) 'expires_at': expiry.millisecondsSinceEpoch ~/ 1000,
      if (token.scope.isNotEmpty) 'scope': token.scope,
      if (token.refreshToken != null) 'refresh_token': token.refreshToken,
    };
  }

  /// Best-effort, exactly like the master store's: a weaker mode is better than
  /// a connector that silently stops working because the write was abandoned.
  Future<void> _restrict(File file) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } on Object {
      // Nothing to do and nothing to say.
    }
  }
}

/// Mirrors Hermes's `_safe_filename` exactly:
///
/// ```python
/// re.sub(r"[^\w\-]", "_", name).strip("_")[:128] or "default"
/// ```
///
/// Transcribed rather than approximated, because the two names have to agree
/// character for character: a mismatch writes a file the agent never opens, and
/// nothing about that failure looks like a bug — the connector is simply, and
/// silently, not connected.
///
/// The trap: **Dart's `\w` is ASCII-only and Python's is not.** Python's `\w`
/// matches any Unicode letter or digit, so `café` and `日本語` survive intact
/// there. Writing `RegExp(r'[^\w\-]')` in Dart mangles both — `unicode: true`
/// does not fix it, since that flag governs surrogate-pair handling rather than
/// what `\w` means. The class below spells out the Unicode sense explicitly.
///
/// Two smaller details, also confirmed against the real function: underscores
/// are stripped from both ends *after* substitution (so `__both__` → `both`),
/// and an empty result becomes `default`, not an underscore.
String safeFileName(String name) {
  final substituted = name.replaceAll(
    RegExp(r'[^\p{L}\p{N}_\-]', unicode: true),
    '_',
  );
  final stripped = substituted.replaceAll(RegExp(r'^_+|_+$'), '');
  final clipped = stripped.length > 128 ? stripped.substring(0, 128) : stripped;
  return clipped.isEmpty ? 'default' : clipped;
}

final hermesTokenProjectionProvider = Provider<HermesTokenProjection>(
  (ref) => HermesTokenProjection(),
);
