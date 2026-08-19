import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/scheduled/logic/task_conversation_id.dart';
import 'package:grid_app/features/scheduled/logic/task_destination.dart';

Conversation _chat(String id) => Conversation(
  id: id,
  title: id,
  model: 'm',
  createdAt: DateTime(2026, 8, 19),
  updatedAt: DateTime(2026, 8, 19),
);

void main() {
  group('the destination a task carries in Hermes\'s own store', () {
    test('a chat destination round-trips, so the app reads back the thread it '
        'wrote', () {
      const written = TaskChatDestination('1787048651932741');
      final read = parseTaskDeliver(taskDeliverValue(written));

      expect(read, isA<TaskChatDestination>());
      expect((read as TaskChatDestination).chatId, '1787048651932741');
    });

    test('a project destination round-trips too', () {
      const written = TaskProjectDestination('proj-7');
      final read = parseTaskDeliver(taskDeliverValue(written));

      expect((read as TaskProjectDestination).projectId, 'proj-7');
    });

    test("the task's own chat stays plain `local`, so Hermes still writes the "
        'result file every other destination also relies on', () {
      expect(taskDeliverValue(const TaskOwnChat()), 'local');
    });

    test('every task made before destinations existed reads as its own chat, '
        'rather than losing its results to an unknown target', () {
      for (final stored in [
        null,
        '',
        'local',
        'telegram',
        'grid:',
        'grid:x:1',
        'grid:chat:',
        'grid:chat',
      ]) {
        expect(
          parseTaskDeliver(stored),
          isA<TaskOwnChat>(),
          reason: 'deliver=$stored',
        );
      }
    });
  });

  group('choosing the conversation a result lands in', () {
    test('the chat the task was set up in, when it is still there', () {
      final into = taskDeliveryChatId(
        const TaskChatDestination('c1'),
        'job-1',
        [_chat('c1'), _chat('c2')],
      );

      expect(into, 'c1');
    });

    test('a deleted chat falls back to the task\'s own rather than dropping '
        'the answer somewhere nothing can show it', () {
      final into = taskDeliveryChatId(
        const TaskChatDestination('gone'),
        'job-1',
        [_chat('c1')],
      );

      expect(into, taskConversationId('job-1'));
    });

    test('a project task keeps a thread of its own, so a daily run does not '
        "interleave with whatever the user is doing in the project", () {
      final into = taskDeliveryChatId(
        const TaskProjectDestination('proj-7'),
        'job-1',
        [_chat('c1')],
      );

      expect(into, taskConversationId('job-1'));
      expect(
        taskDestinationProjectId(const TaskProjectDestination('proj-7')),
        'proj-7',
      );
    });

    test(
      'a chat destination files under no project — only a project one does',
      () {
        expect(
          taskDestinationProjectId(const TaskChatDestination('c1')),
          isNull,
        );
        expect(taskDestinationProjectId(const TaskOwnChat()), isNull);
      },
    );
  });
}
