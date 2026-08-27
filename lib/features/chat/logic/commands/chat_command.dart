/// A slash command the **app** runs, rather than a message it sends.
///
/// Grid drives three different agents over three different transports, and each
/// agent's own `/commands` live inside the piece of it Grid doesn't talk to —
/// Codex's are in its TUI crate, for instance. So a command that has to work
/// "for every agent" can only be one the app itself performs, on the state the
/// app itself owns: the transcript and the open chat.
///
/// That is also why the list is two long and stays two long. Everything else
/// typed with a slash goes to the agent **exactly as typed** — the app used to
/// own `/goal`, `/loop` and `/schedule` as well, and read the agent's replies
/// for blocks asking for them; all of that went on 2026-08-27, by decision:
/// the app sends what the user wrote and shows what the agent sent back,
/// nothing in between.
enum ChatCommand {
  /// Start a fresh chat where the user is standing — issue #33's sibling,
  /// issue #13: typing `/clear` used to be sent to the assistant as text, which
  /// is exactly nothing.
  clear(
    name: 'clear',
    summary: 'Start a new chat here',
    detail: 'Keeps you where you are — in this project, or in the chat list.',
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

  /// Why the pictures, files and quoted selections sitting on the composer
  /// don't go with this command, or null when they stay put.
  ///
  /// `/clear` leaves the composer behind, so an attachment left on it would
  /// ride into whatever the user types next — which is how one sat there after
  /// a send looking like part of the message that had just gone.
  ///
  /// `/compact` is the exception, because it sends nothing at all: the user is
  /// still writing the message those attachments belong to, and freeing up
  /// room mid-draft must not cost them the picture they just attached.
  String? get draftDropReason => switch (this) {
    ChatCommand.clear => 'a new chat starts empty',
    ChatCommand.compact => null,
  };

  /// Whether the **app** still performs this in a chat drawn as the agent's own
  /// terminal, instead of handing the typed line to the CLI.
  ///
  /// In a terminal chat the CLI owns the conversation: the app commits nothing
  /// to the transcript, and a command routed through the app's own turn lane
  /// runs in a `claude -p` nobody can see, in a *different session* from the one
  /// on screen. So only `/clear` stays: it starts a new chat where the user is
  /// standing, which is the app's own state and needs no turn at all. `/compact`
  /// goes to the CLI, which has its own.
  bool get appRunsInTerminalChat => this == ChatCommand.clear;
}

/// A command the user has actually typed, with whatever they typed after it.
///
/// A record rather than a class: it carries two fields and no behaviour.
typedef ChatCommandCall = ({ChatCommand command, String argument});

/// What running a command wants said afterwards.
///
/// [failed] is not decoration: "couldn't reach a model" and "done" must never
/// look alike (§5).
typedef CommandOutcome = ({String message, bool failed});

/// What to tell the user when [command] took [names] off the composer.
///
/// Silence here is the bug: an attachment that vanishes the moment a command
/// runs reads as one that went with it, and an attachment left behind reads
/// the same way — so the app says which ones didn't travel. Names the first,
/// like `attachmentOverflowMessage`, so it is clear *what* went. Null when
/// nothing was attached, or when the command leaves the draft alone.
String? droppedDraftMessage(ChatCommand command, List<String> names) {
  final reason = command.draftDropReason;
  if (reason == null || names.isEmpty) return null;
  final rest = names.length - 1;
  final what = rest == 0
      ? '“${names.first}”'
      : '“${names.first}” and $rest more';
  return '$what didn’t come along — $reason.';
}

/// The command [text] invokes, or null when it invokes none.
///
/// Only a leading `/name` counts, and only when `name` is one of ours — so
/// "/usr/local/bin is on PATH", an agent's own `/review` and a `/loop` meant
/// for the CLI are all ordinary messages, sent as typed. Everything after the
/// first space is the argument, trimmed but otherwise untouched: it is the
/// user's words.
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

/// The command the composer should badge itself with while [text] is being
/// written, or null when the line is an ordinary message.
///
/// The `/` menu ([slashQuery]) covers *choosing* a command — a lone `/name` with
/// no space yet. This covers the blind spot right after it: the moment a space
/// is typed the menu closes, and `/compact only the API decisions` reads as an
/// ordinary prompt with nothing saying it will be run rather than sent — which
/// is exactly the thing a user could not tell. The two hand off cleanly (menu
/// while the name is picked, badge once the argument is written) so they never
/// show at once.
ChatCommand? activeComposerCommand(String text) =>
    slashQuery(text) != null ? null : parseChatCommand(text)?.command;

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
