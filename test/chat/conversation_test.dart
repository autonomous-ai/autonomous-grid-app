import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_title.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/chat/logic/import/parsed_session.dart';
import 'package:grid_app/features/chat/logic/interrupted_turn.dart';
import 'package:grid_app/features/chat/logic/routing_group.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/message_media.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

Conversation _conversation({
  String id = 'c1',
  String title = 'Hello',
  String model = 'qwen',
  DateTime? updatedAt,
  List<ChatMessage> messages = const [],
  String? projectId,
  DateTime? archivedAt,
  String? documentPath,
}) {
  final at = updatedAt ?? DateTime(2026, 1, 1, 12);
  return Conversation(
    id: id,
    title: title,
    model: model,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: at,
    messages: messages,
    projectId: projectId,
    archivedAt: archivedAt,
    documentPath: documentPath,
  );
}

void main() {
  group('serialization', () {
    test('round-trips text + media through JSON', () {
      final original = _conversation(
        messages: [
          const ChatMessage(role: ChatRole.user, text: 'draw a cat'),
          const ChatMessage(
            role: ChatRole.assistant,
            media: [ChatMedia(path: '/tmp/cat.png', kind: MediaKind.image)],
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.model, original.model);
      expect(restored.createdAt, original.createdAt);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.messages, hasLength(2));
      expect(restored.messages.first.role, ChatRole.user);
      expect(restored.messages.first.text, 'draw a cat');
      final media = restored.messages.last.media.single;
      expect(media.path, '/tmp/cat.png');
      expect(media.kind, MediaKind.image);
    });

    test('round-trips an agent turn with its web sources', () {
      final original = _conversation(
        messages: [
          const ChatMessage(role: ChatRole.user, text: 'latest flutter news'),
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Here is what I found.',
            sources: [
              WebSource(title: 'Flutter', url: 'https://flutter.dev'),
              WebSource(title: 'Dart', url: 'https://dart.dev'),
            ],
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      final sources = restored.messages.last.sources;
      expect(sources.map((s) => s.url), [
        'https://flutter.dev',
        'https://dart.dev',
      ]);
      // A plain text turn stays sourceless rather than gaining an empty list.
      expect(restored.messages.first.sources, isEmpty);
    });

    test('round-trips the model that answered, so the transcript still names '
        'it after a reload', () {
      final original = _conversation(
        messages: [
          const ChatMessage(role: ChatRole.user, text: 'hi'),
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            model: 'qwen/qwen3.6-27b',
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      expect(restored.messages.last.model, 'qwen/qwen3.6-27b');
      // The user turn carries no model — it isn't an answer.
      expect(restored.messages.first.model, isNull);
    });

    test('round-trips who answered and on which machine, so a chat reopened a '
        'week later still says where the answer came from', () {
      final original = _conversation(
        messages: [
          const ChatMessage(role: ChatRole.user, text: 'hi'),
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            agent: 'codex',
            model: 'qwen/qwen3.6-27b',
            node: 'doggi',
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      expect(restored.messages.last.agent, 'codex');
      expect(restored.messages.last.node, 'doggi');
      // The user's own turn was answered by nobody, on no machine.
      expect(restored.messages.first.agent, isNull);
      expect(restored.messages.first.node, isNull);
    });

    test('a reply the grid answered itself keeps no agent, and one whose '
        'machine could not be told keeps no name — neither is invented on the '
        'way back in', () {
      final original = _conversation(
        messages: [
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            model: 'auto',
          ),
        ],
      );

      final json = original.toJson();
      final stored = (json['messages'] as List).single as Map<String, dynamic>;
      expect(stored.containsKey('agent'), isFalse);
      expect(stored.containsKey('node'), isFalse);

      final restored = Conversation.fromJson(json);
      expect(restored.messages.single.agent, isNull);
      expect(restored.messages.single.node, isNull);
    });

    test('round-trips how long the answer took, so a reopened chat still says '
        'which model was slow and which was not', () {
      final original = _conversation(
        messages: [
          const ChatMessage(role: ChatRole.user, text: 'hi'),
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            model: 'qwen/qwen3.6-27b',
            took: Duration(milliseconds: 8400),
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      expect(restored.messages.last.took, const Duration(milliseconds: 8400));
      expect(restored.messages.first.took, isNull);
    });

    test('round-trips when the first word appeared, which is the half of "was '
        'that slow?" the total cannot answer', () {
      final original = _conversation(
        messages: [
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            model: 'qwen/qwen3.6-27b',
            took: Duration(milliseconds: 8400),
            firstToken: Duration(milliseconds: 1200),
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      expect(
        restored.messages.single.firstToken,
        const Duration(milliseconds: 1200),
      );
    });

    test('round-trips message times so reopened chats still say when each turn '
        'was sent', () {
      final sentAt = DateTime(2026, 8, 24, 21, 17);
      final original = _conversation(
        messages: [
          ChatMessage(
            role: ChatRole.user,
            text: 'When was this?',
            sentAt: sentAt,
          ),
        ],
      );

      final json = original.toJson();
      final stored = (json['messages'] as List).single as Map<String, dynamic>;
      final restored = Conversation.fromJson(json);

      expect(stored['sent_at'], sentAt.toUtc().toIso8601String());
      expect(restored.messages.single.sentAt, sentAt);
    });

    test('keeps legacy or malformed message times unknown instead of inventing '
        'one when a chat is reopened', () {
      final legacy = _conversation(
        messages: const [ChatMessage(role: ChatRole.user, text: 'Old turn')],
      ).toJson();
      final malformed = _conversation().toJson()
        ..['messages'] = [
          {'role': 'assistant', 'text': 'Broken stamp', 'sent_at': 'later'},
        ];

      expect(Conversation.fromJson(legacy).messages.single.sentAt, isNull);
      expect(Conversation.fromJson(malformed).messages.single.sentAt, isNull);
    });

    test('a chat saved before turns were timed reloads without one, rather '
        'than claiming it was instant', () {
      final json = _conversation(
        messages: [
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            model: 'qwen',
          ),
        ],
      ).toJson();

      final restored = Conversation.fromJson(json);

      expect(restored.messages.single.took, isNull);
    });

    test(
      'round-trips an agent turn with its to-do plan and each step status',
      () {
        final original = _conversation(
          messages: [
            const ChatMessage(role: ChatRole.user, text: 'refactor the parser'),
            const ChatMessage(
              role: ChatRole.assistant,
              text: 'Done.',
              plan: [
                AgentPlanEntry(
                  content: 'Read the file',
                  status: AgentPlanStatus.done,
                ),
                AgentPlanEntry(
                  content: 'Rewrite it',
                  status: AgentPlanStatus.active,
                ),
                AgentPlanEntry(
                  content: 'Run the tests',
                  status: AgentPlanStatus.pending,
                ),
              ],
            ),
          ],
        );

        final restored = Conversation.fromJson(original.toJson());

        final plan = restored.messages.last.plan;
        expect(plan.map((e) => e.content), [
          'Read the file',
          'Rewrite it',
          'Run the tests',
        ]);
        expect(plan.map((e) => e.status), [
          AgentPlanStatus.done,
          AgentPlanStatus.active,
          AgentPlanStatus.pending,
        ]);
        // A plain text turn stays planless rather than gaining an empty list.
        expect(restored.messages.first.plan, isEmpty);
      },
    );

    test('throws when the id is missing so the store can skip the file', () {
      expect(
        () => Conversation.fromJson(const {'title': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('tolerates a missing messages list', () {
      final restored = Conversation.fromJson(const {'id': 'c9'});
      expect(restored.messages, isEmpty);
      expect(restored.title, kNewConversationTitle);
    });
  });

  test('an imported turn keeps the final source timestamp when adjacent event '
      'pieces are merged', () {
    final first = DateTime.utc(2026, 8, 24, 10);
    final finished = DateTime.utc(2026, 8, 24, 10, 2);
    final drafts = mergeDrafts([
      TurnDraft(ChatRole.assistant, sentAt: first)..say('First'),
      TurnDraft(ChatRole.assistant, sentAt: finished)..say('Second'),
    ]);

    final result = finishDrafts(drafts, agentId: 'codex');

    expect(result.messages.single.sentAt, finished);
  });

  group('deriveConversationTitle', () {
    test('keeps the whole first user line — the rename field can only offer '
        'back what was written down, and every place it is drawn clips it at '
        'the width it actually has', () {
      final title = deriveConversationTitle([
        const ChatMessage(
          role: ChatRole.user,
          text:
              'Explain quantum tunnelling to me like I am five years old '
              'please',
        ),
      ]);
      expect(
        title,
        'Explain quantum tunnelling to me like I am five years old please',
      );
    });

    test('skips assistant turns and blank lines', () {
      final title = deriveConversationTitle([
        const ChatMessage(role: ChatRole.assistant, text: 'Hi there'),
        const ChatMessage(role: ChatRole.user, text: '\n  first ask  \n'),
      ]);
      expect(title, 'First ask');
    });

    test('falls back to the placeholder with no user text', () {
      expect(deriveConversationTitle(const []), kNewConversationTitle);
    });

    // The rows from issue #37: every one of them opened with the same
    // instruction, so the sidebar listed five chats that read alike.
    test('drops the command and the opening, so what is left says which chat '
        'this is', () {
      String named(String text) => deriveConversationTitle([
        ChatMessage(role: ChatRole.user, text: text),
      ]);

      expect(
        named('/goal i want you to work on the pricing page'),
        'Work on the pricing page',
      );
      expect(named('help me edit this X post'), 'Edit this X post');
      expect(
        named('/goal check out this benchmark of local models'),
        'This benchmark of local models',
      );
      expect(
        named('/goal study https://roo.dev/docs/quickstart'),
        'Study roo.dev/docs',
      );
      // The openers are English only, so an ask written in another language
      // keeps its own — a limit worth seeing in a test rather than finding in
      // a sidebar.
      expect(
        named('could you please fix the pricing on the home page'),
        'Fix the pricing on the home page',
      );
    });

    test('keeps a message that is only a command, and a path that merely looks '
        'like one', () {
      expect(
        deriveConversationTitle([
          const ChatMessage(role: ChatRole.user, text: '/compact'),
        ]),
        'Compact',
      );
      expect(
        deriveConversationTitle([
          const ChatMessage(role: ChatRole.user, text: '/Users/me/notes.md'),
        ]),
        '/Users/me/notes.md',
      );
    });

    test('is not cut on the way in, so renaming one offers the sentence back '
        'rather than its first forty characters', () {
      final title = deriveConversationTitle([
        const ChatMessage(
          role: ChatRole.user,
          text: 'Rewrite the onboarding checklist for the desktop app',
        ),
      ]);

      expect(title, 'Rewrite the onboarding checklist for the desktop app');
      expect(editableChatTitle(title), title);
    });
  });

  group('tidyChatTitle', () {
    test('takes the shapes a model wraps a one-line answer in back to the '
        'name that was asked for', () {
      expect(tidyChatTitle('"Landing page copy"'), 'Landing page copy');
      expect(tidyChatTitle('Title: Landing page copy.'), 'Landing page copy');
      expect(tidyChatTitle('```\nLanding page copy\n```'), 'Landing page copy');
      expect(tidyChatTitle('   '), '');
    });

    test('keeps a model that answered with a sentence whole — a long name is '
        'the drawing\'s problem, not the store\'s', () {
      expect(
        tidyChatTitle(
          'This conversation is about rewriting the onboarding checklist',
        ),
        'This conversation is about rewriting the onboarding checklist',
      );
    });

    test('a name that has to fit a fixed budget is still cut to one, at a '
        'word boundary — that is what clipChatTitle is for now', () {
      expect(
        clipChatTitle('Rewrite the onboarding checklist for the desktop app'),
        'Rewrite the onboarding checklist for…',
      );
      expect(clipChatTitle('Ford Territory'), 'Ford Territory');
    });
  });

  group('editableChatTitle', () {
    test("drops the clip mark so a rename doesn't keep someone else's "
        'ellipsis', () {
      expect(
        editableChatTitle('Rewrite the onboarding checklist for…'),
        'Rewrite the onboarding checklist for',
      );
    });

    test('leaves a name that was never clipped exactly as it is', () {
      expect(editableChatTitle('Ford Territory'), 'Ford Territory');
    });
  });

  group('liveConversations', () {
    test('hides the archived chats and keeps the order it was given', () {
      final live = liveConversations([
        _conversation(id: 'a'),
        _conversation(id: 'filed', archivedAt: DateTime(2026, 2, 1)),
        _conversation(id: 'b'),
      ]);

      expect(live.map((c) => c.id), ['a', 'b']);
    });
  });

  group('liveChatCountIn', () {
    test("counts only the project's own chats that are still in the rail", () {
      final all = [
        _conversation(id: 'in-1', projectId: 'p1'),
        _conversation(id: 'in-2', projectId: 'p1'),
        _conversation(id: 'elsewhere', projectId: 'p2'),
        _conversation(id: 'loose'),
        _conversation(
          id: 'filed',
          projectId: 'p1',
          archivedAt: DateTime(2026, 2, 1),
        ),
      ];

      // The number on the card has to match the rows the sidebar shows, so an
      // archived chat must not be counted even though it still holds the
      // project.
      expect(liveChatCountIn(all, 'p1'), 2);
      expect(liveChatCountIn(all, 'p2'), 1);
      expect(liveChatCountIn(all, 'unknown'), 0);
    });
  });

  group('a pinned chat', () {
    Conversation chat(String id, {bool pinned = false, DateTime? at}) =>
        Conversation(
          id: id,
          title: id,
          model: 'm',
          createdAt: DateTime(2026),
          updatedAt: at ?? DateTime(2026),
          pinned: pinned,
        );

    test('leads the working history, so the two chats you keep coming back to '
        'stop sliding down the rail', () {
      final ordered = liveConversations([
        chat('newest', at: DateTime(2026, 8, 5)),
        chat('kept', pinned: true, at: DateTime(2026, 1, 1)),
        chat('older', at: DateTime(2026, 7, 1)),
      ]);

      expect([for (final c in ordered) c.id], ['kept', 'newest', 'older']);
    });

    test('keeps its place within the pinned group — pinning is not a sort', () {
      final ordered = liveConversations([
        chat('a', pinned: true, at: DateTime(2026, 8, 5)),
        chat('b', pinned: true, at: DateTime(2026, 8, 4)),
      ]);

      expect([for (final c in ordered) c.id], ['a', 'b']);
    });

    test('survives a restart, and an unpinned chat writes no field at all', () {
      final pinned = chat('p', pinned: true);
      expect(pinned.toJson()['pinned'], isTrue);
      expect(chat('u').toJson().containsKey('pinned'), isFalse);

      final read = Conversation.fromJson(pinned.toJson());
      expect(read.pinned, isTrue);
      // A file from before pinning existed reads as unpinned rather than
      // throwing.
      expect(Conversation.fromJson(chat('u').toJson()).pinned, isFalse);
    });
  });

  group('the document a chat belongs to', () {
    test('survives a restart, so the sidebar row still opens its file', () {
      final paired = _conversation(
        documentPath: '/Users/me/Documents/Report.docx',
      );

      final read = Conversation.fromJson(paired.toJson());

      expect(read.documentPath, '/Users/me/Documents/Report.docx');
    });

    test('an ordinary chat writes no field, and one saved before Docs existed '
        'reads as ordinary rather than as a chat with no file', () {
      final plain = _conversation();
      expect(plain.toJson().containsKey('documentPath'), isFalse);
      expect(Conversation.fromJson(plain.toJson()).documentPath, isNull);
    });

    test('an empty path reads as no document — a chat that opened Docs and '
        'then found nothing to show would be worse than a plain chat', () {
      final json = _conversation().toJson()..['documentPath'] = '';

      expect(Conversation.fromJson(json).documentPath, isNull);
    });
  });

  group('the routing mode a chat is pinned to', () {
    test('lastRequestWatermark survives a restart, so a resumed poll knows '
        'where it left off', () {
      final marked = _conversation().copyWith(lastRequestWatermark: 'wm-123');

      final read = Conversation.fromJson(marked.toJson());

      expect(read.lastRequestWatermark, 'wm-123');
    });

    test('a chat with no watermark writes no field at all, so a file saved '
        'before this existed stays byte-identical', () {
      final plain = _conversation();
      expect(plain.toJson().containsKey('lastRequestWatermark'), isFalse);
      expect(
        Conversation.fromJson(plain.toJson()).lastRequestWatermark,
        isNull,
      );
    });

    test('a routing group survives a restart, so a chat pinned to Brute '
        'Force reopens still pinned to it', () {
      const group = RoutingGroup(
        mode: RoutingMode.bruteForce,
        isFixed: true,
        models: ['qwen2.5-72b', 'llama-3.1-70b'],
      );
      final withGroup = _conversation().copyWith(routingGroup: group);

      final read = Conversation.fromJson(withGroup.toJson());

      expect(read.routingGroup, group);
    });

    test('an ordinary chat writes no routingGroup field, and one saved '
        'before routing modes existed reads as ordinary rather than pinned '
        'to a mode nobody chose', () {
      final plain = _conversation();
      expect(plain.toJson().containsKey('routingGroup'), isFalse);
      expect(Conversation.fromJson(plain.toJson()).routingGroup, isNull);
    });

    test('clearRoutingGroup removes a previously-set group, the way '
        'clearArchivedAt un-archives — `?? this` alone could never say null '
        'on purpose', () {
      final withGroup = _conversation().copyWith(
        routingGroup: const RoutingGroup(
          mode: RoutingMode.judgeLoop,
          isFixed: true,
          worker: 'a',
          judge: 'b',
        ),
      );

      final cleared = withGroup.copyWith(clearRoutingGroup: true);

      expect(cleared.routingGroup, isNull);
      expect(cleared.toJson().containsKey('routingGroup'), isFalse);
    });
  });

  group('the model field a turn puts on the wire', () {
    test('an ordinary chat sends exactly the model the composer shows, so '
        'nothing about routing changes a chat that was never routed', () {
      expect(wireModelFor(_conversation(), 'qwen'), 'qwen');
    });

    test('a Fixed chat sends its pinned models rather than the composer\'s '
        'id — the whole point of pinning is that the grid stops choosing', () {
      final pinned = _conversation(model: 'auto/brute_force').copyWith(
        routingGroup: const RoutingGroup(
          mode: RoutingMode.bruteForce,
          isFixed: true,
          models: ['a', 'b'],
        ),
      );

      expect(
        wireModelFor(pinned, 'auto/brute_force'),
        '{"mode":"brute_force","models":["a","b"]}',
      );
    });

    test('a Dynamic chat sends the plain mode string every turn, so the grid '
        'picks afresh each time and no model list is implied', () {
      final dynamicChat = _conversation(model: 'auto/judge_loop').copyWith(
        routingGroup: const RoutingGroup(
          mode: RoutingMode.judgeLoop,
          isFixed: false,
        ),
      );

      expect(wireModelFor(dynamicChat, 'auto/judge_loop'), 'auto/judge_loop');
    });

    test('a chat whose composer has moved off the mode stops sending the '
        'group — switching to a grid with no router drops the pill to a plain '
        'model, and the wire must not go on naming the old grid\'s ids', () {
      // Exactly what `_syncModelField` leaves behind: the group is still on
      // the conversation (nothing on that path clears it) but `model` is a
      // plain id again, because the mode's row is not on the new grid's list.
      final stranded = _conversation(model: 'qwen').copyWith(
        routingGroup: const RoutingGroup(
          mode: RoutingMode.bruteForce,
          isFixed: true,
          models: ['a', 'b'],
        ),
      );

      expect(wireModelFor(stranded, 'qwen'), 'qwen');
    });

    test('a chat on the other mode sends that mode, not the group it still '
        'carries — the group is only ever read for the mode it belongs to', () {
      final swapped = _conversation(model: 'auto/judge_loop').copyWith(
        routingGroup: const RoutingGroup(
          mode: RoutingMode.bruteForce,
          isFixed: true,
          models: ['a', 'b'],
        ),
      );

      expect(wireModelFor(swapped, 'auto/judge_loop'), 'auto/judge_loop');
    });

    test('the Auto agent\'s swapped-in `auto` does not unpin a Fixed chat — '
        'the guard reads the row the user is on, never what this one turn '
        'happens to go out as', () {
      final pinned = _conversation(model: 'auto/brute_force').copyWith(
        routingGroup: const RoutingGroup(
          mode: RoutingMode.bruteForce,
          isFixed: true,
          models: ['a', 'b'],
        ),
      );

      // `picked` is the router's own id, which is what the Auto agent sends a
      // turn out on. The chat is still pinned, so the pin still applies.
      expect(
        wireModelFor(pinned, 'auto'),
        '{"mode":"brute_force","models":["a","b"]}',
      );
    });
  });

  group('a turn the app went away in the middle of', () {
    test('a transcript ending in the user is a turn that never came back', () {
      final cut = _conversation(
        messages: const [ChatMessage(role: ChatRole.user, text: 'keep going')],
      );
      expect(wasTurnInterrupted(cut), isTrue);
    });

    test(
      'an answered turn is not interrupted, and neither is an empty chat',
      () {
        final answered = _conversation(
          messages: const [
            ChatMessage(role: ChatRole.user, text: 'keep going'),
            ChatMessage(role: ChatRole.assistant, text: 'done'),
          ],
        );
        expect(wasTurnInterrupted(answered), isFalse);
        expect(wasTurnInterrupted(_conversation()), isFalse);
      },
    );

    test('marking it closes the turn off, so the next one reads an '
        'interruption instead of a prompt nobody answered', () {
      final marked = markInterruptedTurn(
        _conversation(
          messages: const [
            ChatMessage(role: ChatRole.user, text: 'keep going'),
          ],
        ),
      );
      expect(marked.messages.last.role, ChatRole.assistant);
      expect(marked.messages.last.text, kInterruptedTurnNote);
      // What the user typed is untouched: the note is added, never a rewrite.
      expect(marked.messages.first.text, 'keep going');
    });

    test('marking twice is not two notes — every launch reads the same '
        'history, and only the first one found an open turn', () {
      final once = markInterruptedTurn(
        _conversation(
          messages: const [
            ChatMessage(role: ChatRole.user, text: 'keep going'),
          ],
        ),
      );
      expect(wasTurnInterrupted(once), isFalse);
    });
  });
}
