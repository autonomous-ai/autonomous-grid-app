import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_bot_store.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_rules.dart';
import 'package:grid_app/infrastructure/api/telegram_wire.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

Map<String, Object?> _message({
  String chatType = 'private',
  int fromId = 42,
  String? text = 'hi',
}) => {
  'update_id': 7,
  'message': {
    'message_id': 1,
    'date': 1700000000,
    'chat': {'id': 42, 'type': chatType},
    'from': {'id': fromId, 'first_name': 'Huy'},
    'text': ?text,
  },
};

/// A message carrying [fields] — a photo or a document — and no `text`,
/// which is how Telegram sends a picture.
Map<String, Object?> _picture(Map<String, Object?> fields) {
  final update = _message(text: null);
  return {
    ...update,
    'message': {...update['message']! as Map<String, Object?>, ...fields},
  };
}

void main() {
  group('reading Telegram updates', () {
    test('a private text keeps who sent it and when — what the gate and the '
        'staleness rule decide on', () {
      final update = parseTelegramUpdate(_message()) as TelegramText;

      expect(update.updateId, 7);
      expect(update.chatId, 42);
      expect(update.privateChat, isTrue);
      expect(update.fromId, 42);
      expect(update.fromName, 'Huy');
      expect(update.text, 'hi');
      expect(update.sentAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    });

    test('a group message reads as not private, which keeps the bot out of '
        'groups', () {
      final update = parseTelegramUpdate(_message(chatType: 'group'));

      expect((update as TelegramText).privateChat, isFalse);
    });

    test('a message with nothing to read — a sticker, a voice note — is told '
        'apart from updates to skip, so its sender can be answered', () {
      expect(
        parseTelegramUpdate(_message(text: null)),
        isA<TelegramOtherMessage>(),
      );
    });

    test('a photo reads as its largest size with its caption as the text — '
        'the smaller sizes are thumbnails too small to read', () {
      final update = parseTelegramUpdate(
        _picture({
          'photo': [
            {'file_id': 'big', 'width': 1280, 'height': 960},
            {'file_id': 'thumb', 'width': 90, 'height': 67},
            {'file_id': 'mid', 'width': 320, 'height': 240},
          ],
          'caption': 'what is this error?',
        }),
      );

      expect(update, isA<TelegramText>());
      final message = update! as TelegramText;
      expect(message.pictureId, 'big');
      expect(message.text, 'what is this error?');
    });

    test('a photo with no caption is still a message to answer, not one to '
        'turn away', () {
      final message =
          parseTelegramUpdate(
                _picture({
                  'photo': [
                    {'file_id': 'p', 'width': 800, 'height': 600},
                  ],
                }),
              )!
              as TelegramText;

      expect(message.pictureId, 'p');
      expect(message.text, isEmpty);
    });

    test('a picture sent as a file is read too — how a screenshot keeps its '
        'full size — but any other file is not', () {
      TelegramUpdate? document(String type) => parseTelegramUpdate(
        _picture({
          'document': {'file_id': 'doc', 'mime_type': type},
        }),
      );

      expect((document('image/png')! as TelegramText).pictureId, 'doc');
      expect(document('application/pdf'), isA<TelegramOtherMessage>());
    });

    test("a file keeps the name the sender's own machine gave it, which says "
        'whether it is worth downloading at all', () {
      final update = parseTelegramUpdate(
        _picture({
          'document': {
            'file_id': 'doc',
            'mime_type': 'image/heic',
            'file_name': 'IMG_0001.HEIC',
          },
        }),
      );

      expect((update! as TelegramText).pictureName, 'IMG_0001.HEIC');
    });

    test('a photo has no name of its own — Telegram re-encoded it, and the '
        'name it is stored under is the only one there is', () {
      final update = parseTelegramUpdate(
        _picture({
          'photo': [
            {'file_id': 'small', 'width': 90, 'height': 60},
          ],
        }),
      );

      expect((update! as TelegramText).pictureName, isNull);
    });

    test('a button tap carries the data the bot wrote and where it was', () {
      final update = parseTelegramUpdate({
        'update_id': 8,
        'callback_query': {
          'id': 'cb1',
          'from': {'id': 42},
          'message': {
            'message_id': 5,
            'chat': {'id': 42},
          },
          'data': 'perm:1:allowOnce',
        },
      });

      expect(update, isA<TelegramButtonPress>());
      final press = update! as TelegramButtonPress;
      expect(press.callbackId, 'cb1');
      expect(press.messageId, 5);
      expect(press.data, 'perm:1:allowOnce');
    });

    test('an update Grid has no use for keeps its id, so it is confirmed '
        'rather than delivered again forever', () {
      final update = parseTelegramUpdate({
        'update_id': 9,
        'edited_message': {},
      });

      expect(update, isA<TelegramIgnored>());
      expect(update!.updateId, 9);
    });

    test(
      'an entry with no update id is dropped instead of failing the batch',
      () {
        expect(
          parseTelegramUpdates([
            {'nope': 1},
            _message(),
          ]),
          hasLength(1),
        );
        expect(parseTelegramUpdates('garbage'), isEmpty);
      },
    );

    test('getMe without a username reads as unreadable', () {
      expect(parseTelegramIdentity({'id': 1}), isNull);
      expect(
        parseTelegramIdentity({'id': 1, 'username': 'grid_bot'})?.username,
        'grid_bot',
      );
    });
  });

  group('who the bot answers', () {
    test('only a listed id, and only one to one — a group is refused even for '
        'a listed id, since everyone there reads the answer', () {
      bool may(int from, {bool private = true}) => telegramMayAnswer(
        fromId: from,
        privateChat: private,
        allowed: ['42'],
      );

      expect(may(42), isTrue);
      expect(may(43), isFalse);
      expect(may(42, private: false), isFalse);
    });

    test('a message older than ten minutes is not run: its sender stopped '
        'waiting, and Grid opening is not them asking again', () {
      final now = DateTime(2026, 9, 11, 12);

      expect(
        telegramMessageIsStale(now.subtract(const Duration(minutes: 11)), now),
        isTrue,
      );
      expect(
        telegramMessageIsStale(now.subtract(const Duration(minutes: 9)), now),
        isFalse,
      );
    });
  });

  group('commands', () {
    test("the bot's own commands are read with or without its name", () {
      expect(parseTelegramCommand('/new'), TelegramCommand.fresh);
      expect(parseTelegramCommand('/new@grid_bot'), TelegramCommand.fresh);
      expect(parseTelegramCommand(' /STOP now'), TelegramCommand.stop);
      expect(parseTelegramCommand('/start'), TelegramCommand.start);
    });

    test('anything else goes to the assistant as typed', () {
      expect(parseTelegramCommand('/compact'), isNull);
      expect(parseTelegramCommand('new'), isNull);
    });

    test('what was typed after the command is kept, so /model gpt-5 names a '
        'model instead of quietly opening the menu', () {
      expect(telegramCommandArgument('/model  gpt-5 '), 'gpt-5');
      expect(telegramCommandArgument('/model@grid_bot gpt-5'), 'gpt-5');
      expect(telegramCommandArgument('/model'), '');
    });
  });

  group('chats and answers', () {
    test('two chats started in the same Telegram chat get ids of their own, so '
        '/new never lands back in the chat it was meant to leave', () {
      final first = telegramConversationId(42, DateTime(2026, 9, 11));
      final second = telegramConversationId(42, DateTime(2026, 9, 12));

      expect(first, isNot(second));
      expect(first, startsWith(kTelegramChatPrefix));
    });

    test('a button answers the question it was drawn for and nothing else', () {
      final data = telegramAnswerData(3, AgentPermissionChoice.allowOnce);

      expect(parseTelegramAnswerData(data), (
        ask: 3,
        choice: AgentPermissionChoice.allowOnce,
      ));
      expect(parseTelegramAnswerData('perm:x:refuse'), isNull);
      expect(parseTelegramAnswerData('perm:3:always'), isNull);
      expect(parseTelegramAnswerData('something'), isNull);
    });

    test(
      'Plan becomes Ask, because the plan bar only exists in the window',
      () {
        expect(
          telegramApprovalMode(AgentApprovalMode.plan),
          AgentApprovalMode.ask,
        );
        expect(
          telegramApprovalMode(AgentApprovalMode.full),
          AgentApprovalMode.full,
        );
        expect(
          telegramApprovalMode(AgentApprovalMode.readOnly),
          AgentApprovalMode.readOnly,
        );
      },
    );

    test('a failing poll backs off from two seconds to at most a minute', () {
      expect(telegramRetryDelay(0), const Duration(seconds: 2));
      expect(telegramRetryDelay(1), const Duration(seconds: 4));
      expect(telegramRetryDelay(10), const Duration(seconds: 60));
    });
  });

  group('the saved bot', () {
    late Directory dir;
    late TelegramBotStore store;
    const config = TelegramBotConfig(
      token: '8123456789:AAFabcdefghijklmnopqrstuvwxyz',
      allowedUsers: ['42'],
      botName: 'grid_bot',
      threads: {'42': 'telegram-42-1'},
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('telegram_store');
      store = TelegramBotStore(file: File('${dir.path}/app/telegram_bot.json'));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('round-trips, so the bot answers again after a restart', () async {
      await store.write(config);

      expect(await store.read(), config);
    });

    test(
      'a missing or unreadable file is no bot, so the screen still opens',
      () async {
        expect(await store.read(), isNull);
        store.file
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('{not json');
        expect(await store.read(), isNull);
      },
    );

    test('a bot saved with nobody allowed reads as no bot — never as one that '
        'answers anyone', () {
      expect(
        TelegramBotConfig.fromJson({'token': 't', 'allowed_users': <String>[]}),
        isNull,
      );
    });

    test('/new points one chat at a fresh Grid chat and leaves the others', () {
      final moved = config
          .withThread(7, 'telegram-7-1')
          .withThread(42, 'telegram-42-2');

      expect(moved.threadFor(42), 'telegram-42-2');
      expect(moved.threadFor(7), 'telegram-7-1');
    });
  });
}
