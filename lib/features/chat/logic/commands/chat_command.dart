/// A slash command the **app** runs, rather than a message it sends.
///
/// Grid drives four different agents over four different transports, and each
/// agent's own `/commands` live inside the piece of it Grid doesn't talk to —
/// Codex's are in its TUI crate, Pi's in its interactive mode (see
/// `docs/agent-commands.md`). So a command that has to work "for every agent"
/// can only be one the app itself performs, on the state the app itself owns:
/// the transcript, the open chat, the turn loop.
///
/// That is also why the list is short and will stay short. A command earns its
/// place by doing something no message could ask an agent to do.
enum ChatCommand {
  /// Start a fresh chat where the user is standing — issue #33's sibling,
  /// issue #13: typing `/clear` used to be sent to the assistant as text, which
  /// is exactly nothing.
  clear(
    name: 'clear',
    summary: 'Start a new chat here',
    detail: 'Keeps you where you are — in this project, or in the chat list.',
  ),

  /// Work toward a condition across turns until a second model says it holds.
  /// The argument is the condition, or one of [kGoalClearWords], or nothing at
  /// all (which asks for the status).
  goal(
    name: 'goal',
    summary: 'Keep working until something is true',
    detail:
        'Write the finished state — "the tests in test/auth pass". It keeps '
        'going by itself until a check says so, or says it never will.',
  ),

  /// Summarize the conversation so the next turn carries the summary instead of
  /// the whole history. Takes optional focus instructions.
  compact(
    name: 'compact',
    summary: 'Summarize this chat to free up room',
    detail:
        'Nothing is deleted — the assistant carries a summary from here on. '
        'Add words after it to say what the summary should keep.',
  );

  const ChatCommand({
    required this.name,
    required this.summary,
    required this.detail,
  });

  /// What the user types after the slash.
  final String name;

  /// The one line the menu shows beside the name.
  final String summary;

  /// The second line: what it does to the thing in front of them.
  final String detail;

  /// How it reads in the menu and in the composer.
  String get slash => '/$name';
}

/// A command the user has actually typed, with whatever they typed after it.
///
/// A record rather than a class: it carries two fields and no behaviour.
typedef ChatCommandCall = ({ChatCommand command, String argument});

/// What running a command wants said afterwards.
///
/// [failed] is not decoration: "couldn't reach a model" and "done" must never
/// look alike, which is the whole lesson of the goal bar that said one word for
/// four different endings (§5).
typedef CommandOutcome = ({String message, bool failed});

/// The command [text] invokes, or null when it invokes none.
///
/// Only a leading `/name` counts, and only when `name` is one of ours — so
/// "/usr/local/bin is on PATH" and an agent's own `/review` are still ordinary
/// messages, sent as typed. Everything after the first space is the argument,
/// trimmed but otherwise untouched: it is the user's words.
ChatCommandCall? parseChatCommand(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('/')) return null;
  final space = trimmed.indexOf(RegExp(r'\s'));
  final name = space < 0 ? trimmed.substring(1) : trimmed.substring(1, space);
  final command = chatCommandNamed(name);
  if (command == null) return null;
  final argument = space < 0 ? '' : trimmed.substring(space + 1).trim();
  return (command: command, argument: argument);
}

/// What is being typed after a leading `/` in the composer, or null when the
/// user isn't typing a command at all.
///
/// A command is a single leading-`/` token with no whitespace: `/cle` gives
/// `cle`, a lone `/` gives the empty string (show everything), and plain text or
/// a `/` followed by a space gives null — by then they have moved on to writing
/// a message that happens to start with a slash.
String? slashQuery(String text) {
  if (!text.startsWith('/')) return null;
  final rest = text.substring(1);
  if (rest.contains(RegExp(r'\s'))) return null;
  return rest;
}

/// The command called [name], or null. Case-insensitive: a user who typed
/// `/Clear` meant `/clear`.
ChatCommand? chatCommandNamed(String name) {
  final needle = name.trim().toLowerCase();
  for (final command in ChatCommand.values) {
    if (command.name == needle) return command;
  }
  return null;
}

/// The commands whose name starts with [query], for the `/` menu.
///
/// Prefix rather than substring: the user is typing a command from its first
/// letter, and a menu that jumped to `/compact` on "c" while they were three
/// letters into `/clear` would be picking for them.
List<ChatCommand> matchingChatCommands(String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return ChatCommand.values;
  return [
    for (final command in ChatCommand.values)
      if (command.name.startsWith(needle)) command,
  ];
}
