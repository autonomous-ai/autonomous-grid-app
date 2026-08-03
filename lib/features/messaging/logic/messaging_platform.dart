import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// One step in a platform's "make a bot" instructions — numbered so the form can
/// lay them out consistently across every platform.
typedef ConnectStep = ({int number, String title, String detail});

/// One secret a platform's connect form collects and writes into Hermes's `.env`
/// under [envKey] — a bot token, plus (for Slack) an app token for Socket Mode.
class CredentialField {
  const CredentialField({
    required this.envKey,
    required this.label,
    required this.hint,
    this.validate,
  });

  /// The `.env` key Hermes reads this secret from (e.g. `SLACK_BOT_TOKEN`).
  final String envKey;
  final String label;
  final String hint;

  /// A line to show when the pasted value is the wrong shape, or null when it's
  /// fine — turning "the bot never answers" into an error the user can fix before
  /// connecting.
  final String? Function(String value)? validate;
}

/// A chat platform the assistant can answer from — Telegram, Discord or Slack.
///
/// They differ only in data: which secrets to collect, which `.env` keys Hermes
/// reads them from, and the words a person recognises. One generalised gateway,
/// controller and screen drive all three off this, so adding the next platform is
/// a new entry here, not a new feature.
enum MessagingPlatform {
  telegram(
    key: 'telegram',
    label: 'Telegram',
    icon: LucideIcons.send,
    allowedUsersKey: 'TELEGRAM_ALLOWED_USERS',
    homeChannelKey: 'TELEGRAM_HOME_CHANNEL',
    homeChannelIsUserId: true,
    credentials: [
      CredentialField(
        envKey: 'TELEGRAM_BOT_TOKEN',
        label: 'Bot token',
        hint: '8123456789:AAF…',
        validate: validateTelegramToken,
      ),
    ],
    userIdLabel: 'Your Telegram id',
    userIdHint: '123456789',
    userIdValidate: validateTelegramId,
    steps: [
      (
        number: 1,
        title: 'Make a bot',
        detail:
            'In Telegram, message @BotFather and send /newbot. It gives you a '
            'token — a long line starting with numbers.',
      ),
      (
        number: 2,
        title: 'Find your Telegram id',
        detail:
            'Message @userinfobot. It replies with your id, a number. Only the '
            'people you list here can use your bot.',
      ),
      (
        number: 3,
        title: 'Paste them in',
        detail: 'Then the bot answers you, from this computer.',
      ),
    ],
  ),
  discord(
    key: 'discord',
    label: 'Discord',
    icon: LucideIcons.messageCircle,
    allowedUsersKey: 'DISCORD_ALLOWED_USERS',
    homeChannelKey: null,
    homeChannelIsUserId: false,
    credentials: [
      CredentialField(
        envKey: 'DISCORD_BOT_TOKEN',
        label: 'Bot token',
        hint: 'MTA1…',
        validate: validateDiscordToken,
      ),
    ],
    userIdLabel: 'Your Discord user id',
    userIdHint: '317361883817000000',
    userIdValidate: validateDiscordId,
    steps: [
      (
        number: 1,
        title: 'Make an application',
        detail:
            'At discord.com/developers, create an application, open its Bot '
            'page, and copy the token. Turn on the Message Content intent while '
            "you're there.",
      ),
      (
        number: 2,
        title: 'Invite the bot to your server',
        detail:
            'From OAuth2 ▸ URL Generator pick the bot scope, open the link, and '
            'add it to a server you and the bot share.',
      ),
      (
        number: 3,
        title: 'Find your user id',
        detail:
            'Turn on Developer Mode (Settings ▸ Advanced), right-click your '
            'name, and Copy User ID. Only the ids you list may message it.',
      ),
    ],
  ),
  slack(
    key: 'slack',
    label: 'Slack',
    icon: LucideIcons.hash,
    allowedUsersKey: 'SLACK_ALLOWED_USERS',
    homeChannelKey: null,
    homeChannelIsUserId: false,
    credentials: [
      CredentialField(
        envKey: 'SLACK_BOT_TOKEN',
        label: 'Bot token',
        hint: 'xoxb-…',
        validate: validateSlackBotToken,
      ),
      CredentialField(
        envKey: 'SLACK_APP_TOKEN',
        label: 'App token',
        hint: 'xapp-…',
        validate: validateSlackAppToken,
      ),
    ],
    userIdLabel: 'Your Slack member id',
    userIdHint: 'U01234ABCDE',
    userIdValidate: validateSlackId,
    steps: [
      (
        number: 1,
        title: 'Create a Slack app',
        detail:
            'At api.slack.com/apps create an app, turn on Socket Mode, and add '
            'the message scopes. Install it to your workspace.',
      ),
      (
        number: 2,
        title: 'Copy both tokens',
        detail:
            'The bot token (starts xoxb-) from OAuth & Permissions, and an '
            'app-level token (starts xapp-) from Basic Information.',
      ),
      (
        number: 3,
        title: 'Find your member id',
        detail:
            'In Slack, open your profile ▸ ⋯ ▸ Copy member ID. Only the ids you '
            'list may message it.',
      ),
    ],
  );

  const MessagingPlatform({
    required this.key,
    required this.label,
    required this.icon,
    required this.credentials,
    required this.allowedUsersKey,
    required this.homeChannelKey,
    required this.homeChannelIsUserId,
    required this.userIdLabel,
    required this.userIdHint,
    required this.userIdValidate,
    required this.steps,
  });

  /// Hermes's own platform key — used for `platform_toolsets.<key>`, the
  /// `gateway_state.json` `platforms.<key>` entry, and nothing the user sees.
  final String key;
  final String label;
  final IconData icon;

  /// The secrets to collect, in the order the form shows them.
  final List<CredentialField> credentials;

  /// The `.env` key holding the comma-separated allowlist — who may message the
  /// bot. Empty means *anyone*, which is why the app refuses to connect without
  /// at least one id.
  final String allowedUsersKey;

  /// The `.env` key for where a scheduled task's answer is delivered, or null
  /// when the platform's home is a channel we don't collect yet (Discord, Slack).
  final String? homeChannelKey;

  /// Whether [homeChannelKey] is the user's own id (Telegram — a task's result
  /// goes to their own chat with the bot). False when it's a separate channel.
  final bool homeChannelIsUserId;

  final String userIdLabel;
  final String userIdHint;
  final String? Function(String value) userIdValidate;

  final List<ConnectStep> steps;
}

/// The token @BotFather hands out looks like `8123456789:AAF…`. Checking the
/// shape turns "the bot never answers" into an error the user can fix.
String? validateTelegramToken(String token) {
  final trimmed = token.trim();
  if (trimmed.isEmpty) return 'Paste the token BotFather gave you.';
  if (!RegExp(r'^\d{6,}:[A-Za-z0-9_-]{20,}$').hasMatch(trimmed)) {
    return "That doesn't look like a bot token — it's a long line like "
        '8123456789:AAF… from @BotFather.';
  }
  return null;
}

/// A Telegram user id is a number (@userinfobot tells you yours).
String? validateTelegramId(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) {
    return 'Add your Telegram id, or the bot would answer anyone who finds it.';
  }
  if (!RegExp(r'^\d{5,}$').hasMatch(trimmed)) {
    return 'A Telegram id is a number — message @userinfobot to get yours.';
  }
  return null;
}

/// A Discord bot token is a long dotted string from the Bot page.
String? validateDiscordToken(String token) {
  final trimmed = token.trim();
  if (trimmed.isEmpty) return 'Paste the token from your bot on Discord.';
  if (trimmed.length < 50 || !trimmed.contains('.')) {
    return "That doesn't look like a Discord bot token — copy it from the "
        "application's Bot page.";
  }
  return null;
}

/// A Discord user id is a numeric snowflake (17–20 digits).
String? validateDiscordId(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) {
    return 'Add your Discord id, or the bot would answer anyone who finds it.';
  }
  if (!RegExp(r'^\d{17,20}$').hasMatch(trimmed)) {
    return 'A Discord id is a long number — right-click your name ▸ Copy User '
        'ID (Developer Mode on).';
  }
  return null;
}

/// A Slack bot token starts with `xoxb-`.
String? validateSlackBotToken(String token) {
  final trimmed = token.trim();
  if (trimmed.isEmpty) return 'Paste the bot token (starts xoxb-).';
  if (!RegExp(r'^xoxb-[A-Za-z0-9-]+$').hasMatch(trimmed)) {
    return 'A Slack bot token starts with xoxb- — copy it from OAuth & '
        'Permissions.';
  }
  return null;
}

/// A Slack app-level token starts with `xapp-` (Socket Mode).
String? validateSlackAppToken(String token) {
  final trimmed = token.trim();
  if (trimmed.isEmpty) return 'Paste the app token (starts xapp-).';
  if (!RegExp(r'^xapp-[A-Za-z0-9-]+$').hasMatch(trimmed)) {
    return 'A Slack app token starts with xapp- — make one under Basic '
        'Information.';
  }
  return null;
}

/// A Slack member id starts with `U` (or `W`), then letters and digits.
String? validateSlackId(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) {
    return 'Add your Slack id, or the bot would answer anyone who finds it.';
  }
  if (!RegExp(r'^[UW][A-Z0-9]{6,}$').hasMatch(trimmed)) {
    return 'A Slack member id looks like U01234ABCDE — profile ▸ ⋯ ▸ Copy '
        'member ID.';
  }
  return null;
}
