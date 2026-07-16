import 'hermes_config_file.dart';

/// What a message from a chat platform (Telegram, Discord, Slack) is allowed to
/// do to this computer.
///
/// These are *remote* surfaces: whoever is on the bot's allowlist types from
/// their phone, with nobody at the machine to approve anything. Hermes's own
/// defaults hand each one "full access ... terminal", which would give a remote
/// chat the run of this computer. So the app pins the same read-and-answer set a
/// scheduled task gets — no terminal, no code execution, no browser, no computer
/// control — by writing `platform_toolsets.<platform>`.
///
/// Real enforcement, not a promise: a tool that isn't loaded can't be called. It
/// takes effect the next time the gateway (re)starts, which is why the messaging
/// controller restricts *before* it restarts the gateway.
class HermesPlatformPolicy {
  HermesPlatformPolicy({String? home}) : _config = HermesConfigFile(home: home);

  final HermesConfigFile _config;

  /// Pin the platform Hermes calls [platformKey] to read-and-answer. Idempotent
  /// — safe to call on every connect and every start, so a bot connected before
  /// this limit existed is brought under it the next time the user touches it.
  Future<void> restrict(String platformKey) => _config.edit((editor) {
    HermesConfigFile.upsert(editor, [
      'platform_toolsets',
      platformKey,
    ], kReadAndAnswerToolsets);
  });

  /// Whether [platformKey] is already held to read-and-answer — a terminal-free
  /// toolset list is saved for it. Lets a caller skip a needless restart.
  Future<bool> isRestricted(String platformKey) async {
    final toolsets = await _config.valueAt(['platform_toolsets', platformKey]);
    if (toolsets is! List) return false;
    return !toolsets.contains('terminal') &&
        !toolsets.contains('code_execution');
  }
}
