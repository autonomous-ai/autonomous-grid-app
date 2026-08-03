import '../../../shared/layouts/shell_state.dart';
import '../../chat/logic/conversation.dart';
import '../../projects/logic/project.dart';
import '../../scheduled/logic/scheduled_job.dart';

/// One thing the palette can do. A sealed set so every caller handles all of
/// them: the palette lists them, and the runner performs them.
sealed class CommandItem {
  const CommandItem();

  /// What the row reads as — also what the search matches against.
  String get label;

  /// The quiet line on the right (the chat's project, the task's schedule) —
  /// what tells two same-named rows apart. Empty when there's nothing to add.
  String get detail => '';
}

/// Open a chat you already had.
class OpenChatCommand extends CommandItem {
  const OpenChatCommand(this.chat, {this.projectName});

  final Conversation chat;

  /// The project the chat lives in, when it lives in one.
  final String? projectName;

  @override
  String get label => chat.title;

  @override
  String get detail => projectName ?? '';
}

/// Start a chat — in [project] when the user picked one.
class NewChatCommand extends CommandItem {
  const NewChatCommand({this.project});

  final Project? project;

  @override
  String get label =>
      project == null ? 'New chat' : 'New chat in ${project!.name}';
}

/// Open a scheduled task.
class OpenTaskCommand extends CommandItem {
  const OpenTaskCommand(this.job);

  final ScheduledJob job;

  @override
  String get label => job.name;

  @override
  String get detail => job.enabled ? '' : 'Paused';
}

/// Add a folder as a project (the OS picker does the rest).
class AddProjectCommand extends CommandItem {
  const AddProjectCommand();

  @override
  String get label => 'Add a project';
}

/// Open Settings — the screens you set up once, now behind one door. Its own
/// command because "settings" is what a user types when they can't remember
/// whether the thing they want is called Grids, Telegram or This computer.
class OpenSettingsCommand extends CommandItem {
  const OpenSettingsCommand();

  @override
  String get label => 'Settings';
}

/// Jump to one of the app's screens.
class GoToCommand extends CommandItem {
  const GoToCommand(this.section);

  final ShellSection section;

  @override
  String get label => 'Go to ${section.label}';
}

/// A titled run of items, as the palette draws them.
class CommandGroup {
  CommandGroup(this.label, this.items, {int? matched})
    : matched = matched ?? items.length;

  final String label;
  final List<CommandItem> items;

  /// How many matched in total, when [items] is only the first of them — the
  /// group's heading says so, because a list that quietly stops at eight reads
  /// as "that's all there is".
  final int matched;

  /// Whether matches were left out of [items].
  bool get isCapped => matched > items.length;
}

/// The most recent chats offered when the palette opens with nothing typed —
/// enough to reach yesterday's work, not so many the list becomes a scroll.
const int kRecentChatCount = 6;

/// How many matches per group a search shows.
///
/// The palette measures itself against its rows, so every match it returns is
/// one it also lays out — on every keystroke. Eight is more than the panel shows
/// at once and more than ⌘1…⌘9 can reach; past that the answer is a narrower
/// query, not a longer list. The heading says how many were left out.
const int kMaxMatchesPerGroup = 8;

/// What the palette shows for [query].
///
/// Empty query = what you most likely want: the chats you were just in, then the
/// handful of things you can start from here. Typing searches everything you own
/// — chats, projects, scheduled tasks — plus the commands themselves, so "sch"
/// finds both your "Schedule review" chat and the Scheduled screen.
///
/// Matches on the *start* of a word rank above matches buried in the middle: a
/// user typing "we" means "Weekly review", not "Answer we discussed".
List<CommandGroup> searchCommands({
  required String query,
  required List<Conversation> chats,
  required List<Project> projects,
  required List<ScheduledJob> tasks,
}) {
  final chatItems = [
    for (final chat in chats)
      OpenChatCommand(
        chat,
        projectName: projects
            .where((p) => p.id == chat.projectId)
            .firstOrNull
            ?.name,
      ),
  ];
  final commands = <CommandItem>[
    const NewChatCommand(),
    for (final project in projects) NewChatCommand(project: project),
    const AddProjectCommand(),
    const OpenSettingsCommand(),
    for (final section in ShellSection.values)
      if (section.isVisibleForBuild) GoToCommand(section),
  ];
  final taskItems = [for (final job in tasks) OpenTaskCommand(job)];

  final q = query.trim().toLowerCase();
  if (q.isEmpty) {
    return [
      if (chatItems.isNotEmpty)
        CommandGroup('Chats', chatItems.take(kRecentChatCount).toList()),
      CommandGroup('Suggested', [
        const NewChatCommand(),
        const AddProjectCommand(),
        const GoToCommand(ShellSection.scheduled),
        const GoToCommand(ShellSection.projects),
      ]),
    ];
  }

  return [
    for (final group in [
      ('Chats', _rank(chatItems, q)),
      ('Scheduled', _rank(taskItems, q)),
      ('Commands', _rank(commands, q)),
    ])
      if (group.$2.isNotEmpty)
        CommandGroup(
          group.$1,
          group.$2.take(kMaxMatchesPerGroup).toList(),
          matched: group.$2.length,
        ),
  ];
}

/// Every item in reading order — what the arrow keys walk and what ⌘1…⌘9 point
/// at, so the number beside a row is the number that opens it.
List<CommandItem> flattenCommands(List<CommandGroup> groups) => [
  for (final group in groups) ...group.items,
];

/// Items that match [query], best first: what the label *begins* with, then what
/// a word inside it begins with, then a match buried anywhere. Typing "we" wants
/// "Weekly review" before "what we discussed" before "answered".
List<T> _rank<T extends CommandItem>(List<T> items, String query) {
  final label = <T>[];
  final word = <T>[];
  final anywhere = <T>[];
  for (final item in items) {
    final text = item.label.toLowerCase();
    if (text.startsWith(query)) {
      label.add(item);
    } else if (text.split(RegExp(r'\s+')).any((w) => w.startsWith(query))) {
      word.add(item);
    } else if (text.contains(query)) {
      anywhere.add(item);
    }
  }
  return [...label, ...word, ...anywhere];
}
