import 'dart:convert';
import 'dart:io';

import 'env_file.dart';
import 'host_environment.dart';

/// Raised when a `hermes gateway` command fails, carrying the line the CLI
/// printed so the controller can show it instead of inventing a message.
class HermesGatewayException implements Exception {
  const HermesGatewayException(this.message);

  final String message;

  @override
  String toString() => 'HermesGatewayException: $message';
}

/// The live link for one messaging platform, read from the gateway's own
/// `gateway_state.json` — the truth about whether the bot connected, not a guess
/// from a heartbeat.
///
/// [state] is Hermes's own word for the platform
/// (`connected`/`connecting`/`retrying`/`disconnected`/`fatal`/`paused`), or
/// empty when the running gateway has no entry for it yet — i.e. the credentials
/// aren't loaded. [error] is the gateway's reason when it isn't connected.
typedef PlatformLinkStatus = ({String state, String? error});

/// Drives Hermes's messaging gateway — the thing that lets the user talk to the
/// assistant from Telegram, Discord or Slack, and lets a scheduled task send its
/// answer there.
///
/// The gateway is Hermes's, not the app's: it runs as a background service on
/// this computer, reads its credentials from `~/.hermes/.env`, and answers with
/// the same grid and model the Chat tab uses. This service is platform-agnostic —
/// it reads and writes raw `.env` keys and reports raw link state; a controller
/// decides which keys a given platform uses.
abstract interface class HermesGatewayService {
  /// Every variable currently set in `~/.hermes/.env`. A disconnected computer
  /// reads as an empty (or key-less) map.
  Future<Map<String, String>> readEnv();

  /// Upsert [values] into `~/.hermes/.env`. [addedBy] is the human note left in
  /// the file so a person reading it later knows what put the line there.
  Future<void> writeEnv(Map<String, String> values, {required String addedBy});

  /// Remove [keys] from `~/.hermes/.env`. A dead token left lying there reads as
  /// "still connected" to anyone who looks, so disconnecting deletes rather than
  /// blanks.
  Future<void> removeEnv(Set<String> keys);

  /// The live link for the platform Hermes calls [platformKey]
  /// (`telegram`/`discord`/`slack`) — whether it actually connected, and why it
  /// didn't. Read from the gateway's own state file, so the screen can't claim
  /// "Answering" when Hermes has the bot marked disconnected.
  Future<PlatformLinkStatus> readLink(String platformKey);

  /// Whether the gateway is actually running. It's what makes the difference
  /// between "connected" and "connected, but nothing is listening".
  Future<bool> running();

  /// Install the background service (once), then restart it so the credentials
  /// just written to `~/.hermes/.env` are actually loaded. A plain start won't
  /// reload a gateway that's already running — the bot would read as connected
  /// but answer nobody — so this restarts to (re)connect the platform.
  Future<void> startGateway();

  /// Restart it, so a credential the user just changed is picked up.
  Future<void> restartGateway();
}

/// Real implementation: writes `~/.hermes/.env` and drives the `hermes` binary.
class HermesGatewayServiceImpl implements HermesGatewayService {
  HermesGatewayServiceImpl(this.binPath, {String? home})
    : _home = home ?? Platform.environment['HOME'] ?? '';

  /// Absolute path to the hermes binary (it isn't on a GUI app's default PATH).
  final String binPath;
  final String _home;

  /// The gateway touches this every few seconds while it runs — one stat instead
  /// of spawning `hermes gateway status`, so the screen can check it on every
  /// refresh. Same signal the scheduler's banner uses.
  static const _heartbeatMaxAge = Duration(seconds: 60);

  EnvFile get _env => EnvFile(File('$_home/.hermes/.env'));

  @override
  Future<Map<String, String>> readEnv() => _env.read();

  @override
  Future<void> writeEnv(
    Map<String, String> values, {
    required String addedBy,
  }) => _env.upsert(values, addedBy: addedBy);

  @override
  Future<void> removeEnv(Set<String> keys) => _env.remove(keys);

  @override
  Future<PlatformLinkStatus> readLink(String platformKey) async {
    final file = File('$_home/.hermes/gateway_state.json');
    if (!file.existsSync()) return (state: '', error: null);
    return parsePlatformLinkStatus(await file.readAsString(), platformKey);
  }

  @override
  Future<bool> running() async {
    final beat = File('$_home/.hermes/cron/ticker_heartbeat');
    if (!beat.existsSync()) return false;
    final seconds = double.tryParse((await beat.readAsString()).trim());
    if (seconds == null) return false;
    final last = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
    return DateTime.now().difference(last) < _heartbeatMaxAge;
  }

  @override
  Future<void> startGateway() async {
    // Install (idempotent, and what survives a reboot), then *restart* — not
    // `start`. A gateway that's already running ignores `start` and never
    // re-reads ~/.hermes/.env, so a token the user just connected would never
    // load: the platform stays disconnected on Hermes while this app's
    // heartbeat still reads "running", and the bot answers nobody. Restart
    // reloads the credentials and (re)connects the platform; with the gateway
    // off, restart simply starts it.
    await _run(['gateway', 'install']);
    await _run(['gateway', 'restart']);
  }

  @override
  Future<void> restartGateway() => _run(['gateway', 'restart']);

  Future<void> _run(List<String> args) async {
    final result = await Process.run(
      binPath,
      args,
      environment: {...Platform.environment, 'PATH': HostEnvironment.path()},
    );
    if (result.exitCode == 0) return;
    final stderr = (result.stderr as String).trim();
    final stdout = (result.stdout as String).trim();
    throw HermesGatewayException(stderr.isNotEmpty ? stderr : stdout);
  }
}

/// The ids on a whitelist line, dropping the blanks a hand-typed list collects.
List<String> parseAllowedUsers(String raw) => [
  for (final id in raw.split(','))
    if (id.trim().isNotEmpty) id.trim(),
];

/// Reads `platforms.<platformKey>` out of the gateway's state JSON. Lenient by
/// design: a shape Hermes renames must not throw and blank the screen — anything
/// unreadable reads as "no link" (empty state), which the UI treats as "not
/// answering" rather than a crash.
PlatformLinkStatus parsePlatformLinkStatus(String rawJson, String platformKey) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) return (state: '', error: null);
    final platforms = decoded['platforms'];
    if (platforms is! Map) return (state: '', error: null);
    final platform = platforms[platformKey];
    if (platform is! Map) return (state: '', error: null);
    final state = platform['state'];
    final error = platform['error_message'];
    return (
      state: state is String ? state : '',
      error: error is String && error.trim().isNotEmpty ? error.trim() : null,
    );
  } on FormatException {
    return (state: '', error: null);
  }
}
