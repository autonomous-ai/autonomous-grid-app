/// One step in the "make a bot" instructions — numbered so the form lays them
/// out the same way every time.
typedef ConnectStep = ({int number, String title, String detail});

/// One secret the connect form collects, named by [key] — the bot token.
class CredentialField {
  const CredentialField({
    required this.key,
    required this.label,
    required this.hint,
  });

  /// Names this secret in the map the connect form hands its controller — and
  /// is the `.env` key Hermes kept it under, back when Hermes ran the bot.
  final String key;
  final String label;
  final String hint;
}

/// The chat app the assistant answers from: Telegram, which Grid answers
/// itself (`telegramBotProvider`).
///
/// Discord and Slack went on 2026-09-11. They could only be answered through
/// Hermes's background gateway — with nothing asking before the assistant
/// acted, and nothing of the conversation in Chat. Still an enum, so the screen
/// is drawn from this data rather than from strings scattered through widgets.
enum MessagingPlatform {
  telegram(
    key: 'telegram',
    label: 'Telegram',
    allowedUsersKey: 'TELEGRAM_ALLOWED_USERS',
    homeChannelKey: 'TELEGRAM_HOME_CHANNEL',
    credentials: [
      CredentialField(
        key: 'TELEGRAM_BOT_TOKEN',
        label: 'Bot token',
        hint: '8123456789:AAF…',
      ),
    ],
    userIdLabel: 'Your Telegram id',
    userIdHint: '123456789',
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
        detail:
            'Then message your bot. Grid answers it from this computer while '
            "it's open.",
      ),
    ],
  );

  const MessagingPlatform({
    required this.key,
    required this.label,
    required this.credentials,
    required this.allowedUsersKey,
    required this.homeChannelKey,
    required this.userIdLabel,
    required this.userIdHint,
    required this.steps,
  });

  /// Hermes's own key for the platform — `gateway_state.json`'s
  /// `platforms.<key>` and `platform_toolsets.<key>`. Nothing the user sees.
  final String key;
  final String label;

  /// The secrets to collect, in the order the form shows them.
  final List<CredentialField> credentials;

  /// The `.env` keys Hermes kept a bot's allowlist and scheduled-result chat
  /// under. Read to show — and removed on disconnect — a bot Hermes still runs
  /// from before Grid answered Telegram itself; nothing writes them any more.
  final String allowedUsersKey;
  final String homeChannelKey;

  final String userIdLabel;
  final String userIdHint;

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
