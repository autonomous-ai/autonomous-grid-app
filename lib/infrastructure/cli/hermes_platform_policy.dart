import 'hermes_config_file.dart';

/// What a message from a chat platform (Telegram, Discord, Slack) is allowed to
/// do to this computer: **whatever Hermes itself allows**.
///
/// The app used to pin each platform to a read-and-answer toolset list — no
/// terminal, no code execution — because these are *remote* surfaces: whoever is
/// on the bot's allowlist types from their phone, with nobody at the machine to
/// approve anything.
///
/// TODO(BE): that pin is gone by explicit product decision. A Telegram message
/// now reaches the same tools the in-app chat does, **and nothing asks anyone
/// first** — the approval cards only exist over ACP, in a chat someone is
/// watching. Anyone the bot answers can run commands on this machine. The bot's
/// own allowlist is the only gate left, so who is on it is now a security
/// boundary rather than a convenience.
///
/// What remains here is the *undo*: a config an older build pinned would stay
/// pinned forever otherwise, since Hermes never rewrites a key that exists.
class HermesPlatformPolicy {
  HermesPlatformPolicy({String? home}) : _config = HermesConfigFile(home: home);

  final HermesConfigFile _config;

  /// Drop the read-and-answer pin an older build wrote for [platformKey], so
  /// Hermes falls back to its own defaults for that platform.
  ///
  /// Only removes a list this app wrote — one that matches
  /// [kReadAndAnswerToolsets] exactly. A list the user chose themselves, or one
  /// Hermes seeded (`hermes-telegram` and friends), is left alone: undoing our
  /// own change must not become editing theirs. Idempotent, and called before
  /// every gateway (re)start, so the repair lands the next time the user touches
  /// the bot.
  Future<void> unpin(String platformKey) async {
    if (!await isPinned(platformKey)) return;
    return _config.edit(
      (editor) =>
          HermesConfigFile.remove(editor, ['platform_toolsets', platformKey]),
    );
  }

  /// Whether [platformKey] still carries this app's read-and-answer pin.
  Future<bool> isPinned(String platformKey) async {
    final toolsets = await _config.valueAt(['platform_toolsets', platformKey]);
    if (toolsets is! List) return false;
    return toolsets.length == kReadAndAnswerToolsets.length &&
        toolsets.every(kReadAndAnswerToolsets.contains);
  }
}
