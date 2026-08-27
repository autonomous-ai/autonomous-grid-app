import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/chat_command.dart';

void main() {
  group('what counts as a command', () {
    test('a bare command runs with no argument', () {
      final call = parseChatCommand('/clear');
      expect(call?.command, ChatCommand.clear);
      expect(call?.argument, '');
    });

    test('everything after the name is the argument, kept as typed', () {
      final call = parseChatCommand('/clear  and start on the parser  ');
      expect(call?.command, ChatCommand.clear);
      expect(call?.argument, 'and start on the parser');
    });

    test('a name this app does not own stays an ordinary message — an agent '
        'has its own /review and the app must not eat it', () {
      expect(parseChatCommand('/review'), isNull);
      expect(parseChatCommand('/status'), isNull);
    });

    test('what the user typed after /compact is the focus, not a message', () {
      final call = parseChatCommand('/compact only the API decisions');
      expect(call?.command, ChatCommand.compact);
      expect(call?.argument, 'only the API decisions');
    });

    test('a path that happens to start with a slash is a message', () {
      expect(parseChatCommand('/usr/local/bin is on PATH'), isNull);
    });

    test('case is the user typing, not a different command', () {
      expect(parseChatCommand('/Clear')?.command, ChatCommand.clear);
    });

    test('text with no slash at all is a message', () {
      expect(parseChatCommand('clear the deck'), isNull);
    });
  });

  group('what the menu shows while a command is being typed', () {
    test('a lone slash offers everything', () {
      expect(slashQuery('/'), '');
      expect(matchingChatCommands(''), ChatCommand.values);
    });

    test('a space ends it: the user is writing a message now', () {
      expect(slashQuery('/clear now'), isNull);
      expect(slashQuery('hello'), isNull);
    });

    test('matching is by prefix, so three letters into /clear the menu is '
        'still showing /clear', () {
      expect(matchingChatCommands('cle'), [ChatCommand.clear]);
    });

    test(
      'nothing matches an unknown name, so the menu gets out of the way',
      () {
        expect(matchingChatCommands('zzz'), isEmpty);
      },
    );
  });

  group('the badge that names the command while its argument is typed', () {
    test(
      'the badge takes over the moment the / menu lets go — a space past the '
      'name is where a command stopped looking like a message',
      () {
        // `/compact` with no space: the menu owns it, so no badge.
        expect(activeComposerCommand('/compact'), isNull);
        expect(slashQuery('/compact'), isNotNull);
        // A space in: the menu is gone (slashQuery null) and the badge is on.
        expect(activeComposerCommand('/compact '), ChatCommand.compact);
        expect(
          activeComposerCommand('/compact only the API decisions'),
          ChatCommand.compact,
        );
      },
    );

    test('an ordinary message is never badged, however it starts', () {
      expect(activeComposerCommand('make the font nice'), isNull);
      // A path that only looks like a command stays a message (parseChatCommand).
      expect(activeComposerCommand('/usr/local/bin is on PATH'), isNull);
      // An agent's own command the app does not own is a message too.
      expect(activeComposerCommand('/review the diff'), isNull);
    });

    test("a command the app used to own is the agent's now, so it is neither "
        'badged nor run — it goes out exactly as typed', () {
      for (final line in [
        '/loop 5m check the deploy',
        '/goal the tests pass',
        '/schedule every morning at 8 summarise the inbox',
      ]) {
        expect(parseChatCommand(line), isNull, reason: line);
        expect(activeComposerCommand(line), isNull, reason: line);
      }
    });
  });

  group('what happens to the pictures attached beside a command', () {
    test('the first is named and the rest counted, so the user knows how much '
        'came off', () {
      expect(
        droppedDraftMessage(ChatCommand.clear, const [
          'a.png',
          'b.png',
          'c.md',
        ]),
        '“a.png” and 2 more didn’t come along — a new chat starts empty.',
      );
    });

    test('a new chat starts empty, and says that rather than a line about '
        'what commands carry', () {
      expect(
        droppedDraftMessage(ChatCommand.clear, const ['dome.png']),
        '“dome.png” didn’t come along — a new chat starts empty.',
      );
    });

    test('/compact sends nothing, so the message being drafted keeps its '
        'attachments and there is nothing to report', () {
      expect(ChatCommand.compact.draftDropReason, isNull);
      expect(
        droppedDraftMessage(ChatCommand.compact, const ['dome.png']),
        isNull,
      );
    });

    test('nothing attached, nothing to say', () {
      expect(droppedDraftMessage(ChatCommand.clear, const []), isNull);
    });
  });

  group('a terminal chat hands the line to the CLI', () {
    test(
      'every command that needs a turn goes to the CLI, because in a terminal '
      'chat the app lane runs in a session nobody can see',
      () {
        for (final command in ChatCommand.values.where(
          (c) => c != ChatCommand.clear,
        )) {
          expect(
            command.appRunsInTerminalChat,
            isFalse,
            reason: '${command.slash} must reach the CLI',
          );
        }
      },
    );

    test('/clear stays with the app: starting a new chat where the user is '
        'standing is the app own state and needs no turn at all', () {
      expect(ChatCommand.clear.appRunsInTerminalChat, isTrue);
    });
  });
}
