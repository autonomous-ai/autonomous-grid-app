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

  group('what picking one out of the menu should do', () {
    test('a command that needs words is handed to the user half-typed, not '
        'run bare — picking /goal used to ask for its status and answer '
        '"No goal set."', () {
      expect(ChatCommand.goal.takesArgument, isTrue);
      expect(ChatCommand.loop.takesArgument, isTrue);
    });

    test('a command that needs nothing just runs', () {
      expect(ChatCommand.clear.takesArgument, isFalse);
      // `/compact` takes an optional focus, but bare is the ordinary use, so
      // picking it does the thing rather than leaving a line to finish.
      expect(ChatCommand.compact.takesArgument, isFalse);
    });

    test('every command that takes words says what they are for, since the '
        'menu row is where the user reads it', () {
      for (final command in ChatCommand.values) {
        if (!command.takesArgument) continue;
        expect(command.argumentHint, isNotEmpty, reason: command.name);
      }
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

  group('what happens to the pictures attached beside a command', () {
    test('a repeating prompt goes out as words, so the picture is taken off '
        'the composer instead of riding onto the next message', () {
      expect(
        droppedDraftMessage(ChatCommand.loop, const ['dome.png']),
        '“dome.png” didn’t come along — /loop carries words only.',
      );
    });

    test('the first is named and the rest counted, so the user knows how much '
        'came off', () {
      expect(
        droppedDraftMessage(ChatCommand.goal, const ['a.png', 'b.png', 'c.md']),
        '“a.png” and 2 more didn’t come along — /goal carries words only.',
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
      expect(droppedDraftMessage(ChatCommand.loop, const []), isNull);
    });
  });
}
