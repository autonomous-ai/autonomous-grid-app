import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/command_palette/logic/command_item.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/features/scheduled/logic/scheduled_job.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';

Conversation _chat(String id, String title, {String? projectId}) =>
    Conversation(
      id: id,
      title: title,
      model: 'm',
      projectId: projectId,
      createdAt: DateTime(2026, 7, 14),
      updatedAt: DateTime(2026, 7, 14),
    );

const _project = Project(id: 'p1', name: 'web-v16', path: '/work/web-v16');

const _task = ScheduledJob(
  id: 'j1',
  name: 'Weekly review',
  prompt: 'Summarise the week',
  cron: '0 16 * * 5',
  enabled: true,
);

List<CommandGroup> search(
  String query, {
  List<Conversation> chats = const [],
  List<Project> projects = const [],
  List<ScheduledJob> tasks = const [],
}) => searchCommands(
  query: query,
  chats: chats,
  projects: projects,
  tasks: tasks,
);

void main() {
  test('with nothing typed it offers the chats you were just in, and the few '
      'things you can start from here', () {
    final groups = search(
      '',
      chats: [_chat('1', 'Fix the login bug'), _chat('2', 'Holiday plan')],
      projects: [_project],
    );

    expect(groups.map((g) => g.label), ['Chats', 'Suggested']);
    expect(groups.first.items.map((i) => i.label), [
      'Fix the login bug',
      'Holiday plan',
    ]);
    expect(groups.last.items.first, isA<NewChatCommand>());
  });

  test('an empty history offers no empty "Chats" heading', () {
    expect(search('').map((g) => g.label), ['Suggested']);
  });

  test('typing searches chats, tasks and commands at once', () {
    final groups = search(
      'week',
      chats: [_chat('1', 'Weekly numbers'), _chat('2', 'Holiday plan')],
      tasks: [_task],
    );

    expect(groups.map((g) => g.label), ['Chats', 'Scheduled']);
    expect(groups.first.items.single.label, 'Weekly numbers');
    expect(groups.last.items.single.label, 'Weekly review');
  });

  test('a match at the start of a word beats one buried in the middle — typing '
      '"we" means "Weekly review", not "what we discussed"', () {
    final groups = search(
      'we',
      chats: [_chat('1', 'What we discussed'), _chat('2', 'Weekly numbers')],
    );

    expect(groups.single.items.map((i) => i.label), [
      'Weekly numbers',
      'What we discussed',
    ]);
  });

  test('the screens are reachable by name — "sched" finds Scheduled', () {
    final groups = search('sched');

    final commands = groups.single;
    expect(commands.label, 'Commands');
    expect(
      commands.items.whereType<GoToCommand>().map((c) => c.section),
      contains(ShellSection.scheduled),
    );
  });

  test(
    'a project offers a chat started inside it — the point of a project',
    () {
      final groups = search('web', projects: [_project]);

      final item = groups.single.items.first as NewChatCommand;
      expect(item.label, 'New chat in web-v16');
      expect(item.project, _project);
    },
  );

  test('a chat shows the project it belongs to, which is what tells two '
      'same-named chats apart', () {
    final groups = search(
      'notes',
      chats: [
        _chat('1', 'Notes', projectId: 'p1'),
        _chat('2', 'Notes'),
      ],
      projects: [_project],
    );

    final items = groups.first.items.cast<OpenChatCommand>();
    expect(items.first.detail, 'web-v16');
    expect(items.last.detail, isEmpty);
  });

  test('nothing matching means no groups at all — the palette then says so '
      'rather than showing empty headings', () {
    expect(search('zzz', chats: [_chat('1', 'Holiday plan')]), isEmpty);
  });

  test('flattenCommands walks the rows in the order they are drawn — the ⌘n '
      'beside a row is the row it opens', () {
    final groups = search('', chats: [_chat('1', 'Holiday plan')]);

    final items = flattenCommands(groups);
    expect(items.first.label, 'Holiday plan');
    expect(items[1], isA<NewChatCommand>());
  });
}
