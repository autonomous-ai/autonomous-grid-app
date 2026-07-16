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

/// How Telegram is set up on this computer right now, read from Hermes's own
/// `.env` — so the screen can't claim a connection that isn't there.
typedef TelegramSetup = ({
  /// The bot's token, or empty when no bot is connected.
  String token,

  /// Who is allowed to message the bot. **Empty means nobody is stopped**, which
  /// is why the app refuses to connect without one.
  List<String> allowedUsers,

  /// The chat a scheduled task's result is sent to.
  String homeChannel,
});

/// Drives Hermes's messaging gateway — the thing that lets the user talk to the
/// assistant from Telegram, and lets a scheduled task send its answer there.
///
/// The gateway is Hermes's, not the app's: it runs as a background service on
/// this computer, reads its credentials from `~/.hermes/.env`, and answers with
/// the same grid and model the Chat tab uses. The app only writes the
/// credentials, starts the service, and reports the truth about whether it's up.
abstract interface class HermesGatewayService {
  /// What's configured now. A disconnected computer reads as an empty token.
  Future<TelegramSetup> readTelegram();

  /// Connect a bot. [allowedUsers] is the whitelist — a bot with no whitelist
  /// answers **anyone who finds it**, on the user's own machine, so the caller
  /// must never pass an empty one.
  Future<void> connectTelegram({
    required String token,
    required List<String> allowedUsers,
    required String homeChannel,
  });

  /// Forget the bot. The token is removed from the file, not just ignored — a
  /// dead token left lying there reads as "still connected" to anyone who looks.
  Future<void> disconnectTelegram();

  /// Whether the gateway is actually running. It's what makes the difference
  /// between "connected" and "connected, but nothing is listening".
  Future<bool> running();

  /// Install the background service (once), then restart it so the credentials
  /// just written to `~/.hermes/.env` are actually loaded. A plain start won't
  /// reload a gateway that's already running — the bot would read as connected
  /// but answer nobody — so this restarts to (re)connect the platform.
  Future<void> startGateway();

  /// Restart it, so a token the user just changed is picked up.
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
  Future<TelegramSetup> readTelegram() async {
    final vars = await _env.read();
    return (
      token: vars[kTelegramToken] ?? '',
      allowedUsers: parseAllowedUsers(vars[kTelegramAllowedUsers] ?? ''),
      homeChannel: vars[kTelegramHomeChannel] ?? '',
    );
  }

  @override
  Future<void> connectTelegram({
    required String token,
    required List<String> allowedUsers,
    required String homeChannel,
  }) async {
    if (allowedUsers.isEmpty) {
      throw const HermesGatewayException(
        'A bot with nobody on its list answers anyone who finds it.',
      );
    }
    await _env.upsert({
      kTelegramToken: token,
      kTelegramAllowedUsers: allowedUsers.join(','),
      kTelegramHomeChannel: homeChannel,
    }, addedBy: 'lets you chat with this computer from Telegram');
  }

  @override
  Future<void> disconnectTelegram() => _env.remove({
    kTelegramToken,
    kTelegramAllowedUsers,
    kTelegramHomeChannel,
  });

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

/// The `.env` keys Hermes reads for Telegram (`.env.example`).
const String kTelegramToken = 'TELEGRAM_BOT_TOKEN';
const String kTelegramAllowedUsers = 'TELEGRAM_ALLOWED_USERS';
const String kTelegramHomeChannel = 'TELEGRAM_HOME_CHANNEL';

/// The ids on a whitelist line, dropping the blanks a hand-typed list collects.
List<String> parseAllowedUsers(String raw) => [
  for (final id in raw.split(','))
    if (id.trim().isNotEmpty) id.trim(),
];
