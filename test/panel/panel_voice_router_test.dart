import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_state.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/panel/logic/panel_controller.dart';
import 'package:grid_app/features/panel/logic/panel_voice_router.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/infrastructure/state/panel_recap_store.dart';

void main() {
  const candidates = [
    PanelRouteCandidate(
      id: 'p-1',
      name: 'payments-api',
      recent: 'Retry guard shipped; all 42 tests pass',
    ),
    PanelRouteCandidate(id: 'p-2', name: 'Tài chính', recent: ''),
  ];

  group('what the router is shown', () {
    test('every project arrives with its name and what it has been doing — the '
        'name decides most of it and the recent work breaks the ties', () {
      final prompt = buildPanelRoutePrompt('deploy the api', candidates);
      expect(prompt, contains('id=p-1'));
      expect(prompt, contains('name="payments-api"'));
      expect(prompt, contains('Retry guard shipped'));
      expect(prompt, contains('id=p-2'));
      expect(prompt, contains('name="Tài chính"'));
    });

    test(
      'a project with no history says so rather than arriving blank — a bare '
      'trailing colon reads as missing data, not as a new project',
      () {
        expect(
          buildPanelRoutePrompt('deploy it', candidates),
          contains('(no activity yet)'),
        );
      },
    );

    test('the sentence goes in verbatim and the model is told not to translate '
        'it, because the turn it starts will be read in that language', () {
      final prompt = buildPanelRoutePrompt(
        'reopen the retry guard',
        candidates,
      );
      expect(prompt, contains('reopen the retry guard'));
      expect(prompt, contains('do NOT translate'));
    });

    test(
      'there is no "none" option — the sentence is already said, and "I could '
      "not tell\" leaves the user with nothing to do but say it again",
      () {
        final prompt = buildPanelRoutePrompt('do the thing', candidates);
        expect(prompt, contains('NO "none" option'));
        expect(prompt, contains('exactly one'));
      },
    );
  });

  group('reading the answer', () {
    test('a clean answer is taken as it stands', () {
      final decision = parsePanelRoute(
        '{"chatId":"p-2","confidence":0.91,"reason":"money talk"}',
        candidates,
      );
      expect(decision.chatId, 'p-2');
      expect(decision.confidence, 0.91);
      expect(decision.reason, 'money talk');
      expect(decision.isConfident, isTrue);
    });

    test(
      'a fence or a sentence in front of the JSON does not lose the pick',
      () {
        final decision = parsePanelRoute(
          'Sure! Here you go:\n```json\n'
          '{"chatId":"p-1","confidence":0.9,"reason":"api"}\n```',
          candidates,
        );
        expect(decision.chatId, 'p-1');
      },
    );

    test('an answer that is not JSON at all resolves to the closest project, '
        'never to nothing — the caller is holding a sentence someone said', () {
      final decision = parsePanelRoute('I think the api one?', candidates);
      expect(decision.chatId, 'p-1');
      expect(decision.confidence, 0);
      expect(decision.isConfident, isFalse);
    });

    test(
      'a project id the app never offered is the model inventing one, so the '
      'pick falls back — but its own uncertainty is kept, capped',
      () {
        final decision = parsePanelRoute(
          '{"chatId":"p-99","confidence":0.95,"reason":"invented"}',
          candidates,
        );
        expect(decision.chatId, 'p-1');
        expect(decision.confidence, 0.3);
        expect(
          decision.isConfident,
          isFalse,
          reason: 'an invented id must never dispatch itself',
        );
      },
    );

    test('confidence outside 0..1, or written as a string, is still read', () {
      expect(
        parsePanelRoute(
          '{"chatId":"p-1","confidence":7,"reason":"x"}',
          candidates,
        ).confidence,
        1,
      );
      expect(
        parsePanelRoute(
          '{"chatId":"p-1","confidence":"0.5","reason":"x"}',
          candidates,
        ).confidence,
        0.5,
      );
      expect(
        parsePanelRoute(
          '{"chatId":"p-1","confidence":-2,"reason":"x"}',
          candidates,
        ).confidence,
        0,
      );
    });

    test('a reason long enough to fill the screen is clipped', () {
      final decision = parsePanelRoute(
        '{"chatId":"p-1","confidence":0.9,"reason":"${'x' * 400}"}',
        candidates,
      );
      expect(decision.reason.length, 120);
    });
  });

  group("what each project has been doing", () {
    late Directory tmp;
    late PanelRecapStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('grid_recaps_test');
      store = PanelRecapStore(file: File('${tmp.path}/panel_recaps.json'));
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('a missing file reads as no history rather than throwing', () {
      expect(store.load(), isEmpty);
    });

    test('a corrupt file reads as no history too — the router losing its '
        'context is survivable, the app failing to start is not', () {
      File('${tmp.path}/panel_recaps.json').writeAsStringSync('not json {');
      expect(store.load(), isEmpty);
    });

    test('only the last three turns survive a round trip, newest first', () {
      store.save({
        'p-1': [
          for (var i = 5; i >= 1; i--)
            PanelTurnRecord(
              recap: 'turn $i',
              summary: '',
              at: DateTime(2026, 8, 17, i),
            ),
        ],
      });
      final loaded = store.load()['p-1']!;
      expect(loaded.length, kPanelRecapsKept);
      expect(loaded.map((t) => t.recap), ['turn 5', 'turn 4', 'turn 3']);
    });

    test(
      'an entry with no headline is dropped at the parse boundary — an empty '
      'line in a prompt costs tokens and says nothing',
      () {
        File('${tmp.path}/panel_recaps.json').writeAsStringSync(
          '{"p-1":[{"recap":"","at":"2026-08-17T10:00:00.000"},'
          '{"recap":"real one","at":"2026-08-17T09:00:00.000"}]}',
        );
        expect(store.load()['p-1']!.map((t) => t.recap), ['real one']);
      },
    );

    test('a turn with no summary is still remembered — on a machine with no '
        'model reachable that is the only history there is', () {
      store.save({
        'p-1': [
          PanelTurnRecord(
            recap: 'cheap headline',
            summary: '',
            at: DateTime(2026, 8, 17),
          ),
        ],
      });
      final loaded = store.load()['p-1']!.single;
      expect(loaded.recap, 'cheap headline');
      expect(loaded.summary, isEmpty);
    });
  });

  group('what a tile carries on a cold start', () {
    const project = Project(id: 'p-1', name: 'payments-api', path: '/tmp/api');
    Conversation chat() => Conversation(
      id: 'c-1',
      title: 'Retry the webhook',
      model: 'qwen',
      createdAt: DateTime(2026, 8, 17),
      updatedAt: DateTime(2026, 8, 17),
      projectId: 'p-1',
    );

    test('the REMEMBERED headline and body, not one string drawn twice', () {
      final tile = panelChatFor(
        chat(),
        project,
        const ChatSessionsState(),
        PanelTurnRecord(
          recap: 'Retry guard shipped; all 42 tests pass',
          summary: 'I added an idempotency key before dispatch.',
          at: DateTime(2026, 8, 17),
        ),
      );
      expect(tile.recap, 'Retry guard shipped; all 42 tests pass');
      expect(tile.summary, 'I added an idempotency key before dispatch.');
      expect(
        tile.summary,
        isNot(tile.recap),
        reason: 'the tile and the reader must not be handed the same sentence',
      );
    });

    test(
      'a remembered turn with no body sends none — the reader then says there '
      'is nothing more rather than repeating the headline',
      () {
        final tile = panelChatFor(
          chat(),
          project,
          const ChatSessionsState(),
          PanelTurnRecord(
            recap: 'Fixed the webhook retry loop',
            summary: '',
            at: DateTime(2026, 8, 17),
          ),
        );
        expect(tile.recap, 'Fixed the webhook retry loop');
        expect(tile.summary, isEmpty);
      },
    );

    test('nothing remembered falls back to the chat, which is what there is '
        'before any turn has been summarised', () {
      final tile = panelChatFor(chat(), project, const ChatSessionsState());
      expect(tile.summary, isEmpty);
    });

    test('the tile is the CHAT — its title heads it and its project names the '
        'folder underneath, so two chats in one folder are tellable apart', () {
      final tile = panelChatFor(chat(), project, const ChatSessionsState());
      expect(tile.id, 'c-1');
      expect(tile.name, 'Retry the webhook');
      expect(tile.project, 'payments-api');
    });
  });
}
