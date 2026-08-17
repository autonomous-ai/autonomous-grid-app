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
      expect(parseChatCommand('/compact'), isNull);
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
}
