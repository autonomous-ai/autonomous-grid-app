import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_rail.dart';

void main() {
  group('railShowsByDefault', () {
    test('a new chat always shows the rail — there is room beside the '
        'starters, whatever the width', () {
      expect(railShowsByDefault(isNewChat: true, isWide: true), isTrue);
      expect(railShowsByDefault(isNewChat: true, isWide: false), isTrue);
    });

    test(
      'a wide pane keeps the rail even once a conversation is under way',
      () {
        expect(railShowsByDefault(isNewChat: false, isWide: true), isTrue);
      },
    );

    test('the one auto-hide: a narrow pane with a conversation in it — where '
        'the conversation needs the width and the toggle brings it back', () {
      expect(railShowsByDefault(isNewChat: false, isWide: false), isFalse);
    });
  });
}
