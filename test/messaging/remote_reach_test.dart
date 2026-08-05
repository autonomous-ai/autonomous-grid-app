import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/messaging/logic/remote_reach.dart';

void main() {
  group('what the row says this computer will do without you', () {
    test('nothing connected says nothing at all', () {
      expect(
        remoteReachLabel((platforms: const <String>[], answering: false)),
        isNull,
      );
    });

    test('a bot that is answering says so plainly', () {
      expect(
        remoteReachLabel((platforms: const ['Telegram'], answering: true)),
        'Answering messages from Telegram',
      );
    });

    test('connected but silent must not read like answering — believing your '
        'computer is reachable when it is not is the failure that matters', () {
      final label = remoteReachLabel((
        platforms: const ['Telegram'],
        answering: false,
      ));
      expect(label, contains('is connected, but nothing is answering'));
      expect(label, isNot(startsWith('Answering')));
    });

    test(
      'several platforms read as a sentence, not a comma-separated dump',
      () {
        expect(
          remoteReachLabel((
            platforms: const ['Telegram', 'Discord', 'Slack'],
            answering: true,
          )),
          'Answering messages from Telegram, Discord and Slack',
        );
      },
    );
  });
}
