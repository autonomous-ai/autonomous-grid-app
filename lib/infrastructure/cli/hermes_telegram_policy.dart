import 'hermes_config_file.dart';

/// What a Telegram message is allowed to do to this computer.
///
/// Telegram is a *remote* surface: whoever is on the bot's allowlist types from
/// their phone, with nobody at the machine to approve anything. Hermes's own
/// default for it (`hermes-telegram`) is "full access ... terminal", which would
/// hand a remote chat the run of this computer. So the app pins the same
/// read-and-answer set a scheduled task gets — no terminal, no code execution,
/// no browser, no computer control — by writing `platform_toolsets.telegram`.
///
/// Real enforcement, not a promise: a tool that isn't loaded can't be called. It
/// takes effect the next time the gateway (re)starts, which is why [connect]
/// restricts *before* it restarts the gateway.
class HermesTelegramPolicy {
  HermesTelegramPolicy({String? home}) : _config = HermesConfigFile(home: home);

  final HermesConfigFile _config;

  /// Pin Telegram to read-and-answer. Idempotent — safe to call on every
  /// connect and every start, so a bot connected before this limit existed is
  /// brought under it the next time the user touches it.
  Future<void> restrict() => _config.edit((editor) {
    HermesConfigFile.upsert(editor, [
      'platform_toolsets',
      'telegram',
    ], kReadAndAnswerToolsets);
  });

  /// Whether Telegram is already held to read-and-answer — a terminal-free
  /// toolset list is saved for it. Lets a caller skip a needless restart.
  Future<bool> get isRestricted async {
    final toolsets = await _config.valueAt(['platform_toolsets', 'telegram']);
    if (toolsets is! List) return false;
    return !toolsets.contains('terminal') &&
        !toolsets.contains('code_execution');
  }
}
