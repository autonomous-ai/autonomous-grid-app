import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_bot_store.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_menus.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_rules.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_sessions.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

List<TelegramMenuItem> _items(int count) => [
  for (var i = 0; i < count; i++) (label: 'row $i', value: '$i'),
];

Conversation _chat({
  String id = '1',
  AgentChatSurface? surface = AgentChatSurface.list,
  DateTime? archivedAt,
  String? documentPath,
}) => Conversation(
  id: id,
  title: 'A chat',
  model: '',
  createdAt: DateTime(2026, 9, 11),
  updatedAt: DateTime(2026, 9, 11),
  surface: surface,
  archivedAt: archivedAt,
  documentPath: documentPath,
);

void main() {
  group('menu buttons', () {
    test('a tap reads back as the menu and row it was drawn for, so a button '
        'on an older menu can be told apart from the live one', () {
      const taps = [
        TelegramPickTap(3, 7),
        TelegramPageTap(3, 2),
        TelegramNewHereTap(3),
        TelegramBackTap(3),
        TelegramNoopTap(3),
      ];
      for (final tap in taps) {
        final back = parseTelegramMenuTap(encodeTelegramMenuTap(tap));

        expect(back.runtimeType, tap.runtimeType);
        expect(back!.menu, 3);
      }
      expect((parseTelegramMenuTap('mp:3:7')! as TelegramPickTap).index, 7);
    });

    test('data a menu did not write — a permission answer, a broken one — is '
        'not read as a menu tap', () {
      expect(parseTelegramMenuTap('perm:1:allowOnce'), isNull);
      expect(parseTelegramMenuTap('mp:x:1'), isNull);
      expect(parseTelegramMenuTap('mp:1'), isNull);
    });

    test("button data stays inside Telegram's 64-byte cap", () {
      final data = encodeTelegramMenuTap(const TelegramPickTap(999999, 49));

      expect(utf8.encode(data).length, lessThan(64));
    });
  });

  group('a page of a menu', () {
    test('six rows a page, with Prev, the page count and Next under them', () {
      final rows = telegramMenuRows(menu: 1, items: _items(14), page: 1);

      expect(rows, hasLength(7));
      expect(rows.first.single.label, 'row 6');
      expect(
        [for (final button in rows.last) button.label],
        ['◀️ Prev', '2/3', 'Next ▶️'],
      );
    });

    test('one page needs no navigation row', () {
      expect(
        telegramMenuRows(menu: 1, items: _items(4), page: 0),
        hasLength(4),
      );
    });

    test(
      'a page past the end shows the last one rather than an empty menu',
      () {
        final rows = telegramMenuRows(menu: 1, items: _items(8), page: 5);

        expect(rows.first.single.label, 'row 6');
      },
    );
  });

  group('labels', () {
    final now = DateTime(2026, 9, 11, 12);

    test('how long ago reads the way a list does', () {
      String ago(Duration gap) => telegramAgo(now.subtract(gap), now);

      expect(ago(Duration.zero), 'just now');
      expect(ago(const Duration(minutes: 5)), '5m ago');
      expect(ago(const Duration(hours: 30)), '30h ago');
      expect(ago(const Duration(days: 3)), '3d ago');
      expect(ago(const Duration(days: 30)), '4w ago');
    });

    test('the chat you are in is ticked, and a long title is cut', () {
      final long = telegramSessionLabel(
        title: 'A' * 40,
        updatedAt: now,
        now: now,
        current: true,
      );

      expect(long, startsWith('✅ '));
      expect(long, contains('…'));
      expect(
        telegramSessionLabel(
          title: 'hi',
          updatedAt: now,
          now: now,
          current: false,
        ),
        '💬 hi · just now',
      );
    });
  });

  group('chats a phone can carry on', () {
    test('an ordinary chat drawn as messages can be', () {
      expect(telegramCanContinue(_chat()), isTrue);
    });

    test('a terminal chat cannot — it needs somebody at the keyboard', () {
      expect(
        telegramCanContinue(_chat(surface: AgentChatSurface.terminal)),
        isFalse,
      );
    });

    test("an archived chat, a scheduled task's, or a document's cannot", () {
      expect(telegramCanContinue(_chat(archivedAt: DateTime(2026))), isFalse);
      expect(telegramCanContinue(_chat(id: 'task-daily')), isFalse);
      expect(telegramCanContinue(_chat(documentPath: '/tmp/a.docx')), isFalse);
    });

    test('an empty chat that never recorded how it is drawn is left out — it '
        'may be a terminal one', () {
      expect(telegramCanContinue(_chat(surface: null)), isFalse);
    });
  });

  group('commands and drafts', () {
    const base = TelegramBotConfig(
      token: 't',
      allowedUsers: ['1'],
      botName: 'grid_bot',
    );

    test("/sessions and /model are the bot's own, not the assistant's", () {
      expect(parseTelegramCommand('/sessions'), TelegramCommand.sessions);
      expect(parseTelegramCommand('/model@grid_bot'), TelegramCommand.model);
    });

    test('a new chat keeps its project and model across a restart until its '
        'first message', () {
      final config = base.withThread(
        1,
        'telegram-1-1',
        draft: (projectId: 'p', model: 'm'),
      );

      final back = TelegramBotConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())),
      );

      expect(back, config);
      expect(back!.draftFor('telegram-1-1'), (projectId: 'p', model: 'm'));
    });

    test('moving on from a chat that never started forgets its draft', () {
      final moved = base
          .withThread(1, 'a', draft: (projectId: 'p', model: null))
          .withThread(1, 'b');

      expect(moved.draftFor('a'), isNull);
      expect(moved.threadFor(1), 'b');
    });

    test('a chat that has started keeps no draft', () {
      final started = base
          .withThread(1, 'a', draft: (projectId: null, model: 'm'))
          .withoutDraft('a');

      expect(started.drafts, isEmpty);
      expect(started.threadFor(1), 'a');
    });
  });
}
