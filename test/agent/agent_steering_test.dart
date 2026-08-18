import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_steering.dart';
import 'package:grid_app/infrastructure/cli/codex_app_server_service.dart';
import 'package:grid_app/infrastructure/cli/hermes_steer.dart';
import 'package:grid_app/infrastructure/logging/app_log.dart';

/// Keeps what was logged, so a refusal can be shown to leave a record rather
/// than only a message that quietly went back in the queue (§6).
class _RecordingLog implements AppLog {
  final lines = <String>[];

  @override
  void record(
    AppLogLevel level,
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => lines.add('$level $category $message');
}

void main() {
  group('the call that steers a running Codex turn', () {
    test('names the turn it means to steer, so a message typed during one turn '
        'cannot land in the next', () {
      final params = codexSteerParams(
        threadId: 'thread-1',
        turnId: 'turn-9',
        text: 'just look at the main file',
      );

      expect(params['threadId'], 'thread-1');
      // Codex checks this against the turn actually running and refuses when it
      // has moved on — see [codexSteerParams].
      expect(params['expectedTurnId'], 'turn-9');
      expect(params['input'], [
        {'type': 'text', 'text': 'just look at the main file'},
      ]);
    });
  });

  group('the prompt that steers a running Hermes turn', () {
    test('carries the command its adapter matches on', () {
      expect(
        hermesSteerPrompt('  just look at the main file  '),
        '/steer just look at the main file',
      );
    });

    test("the adapter's own answers are told apart from the model's, so they "
        "never end up pasted into the middle of an answer", () {
      expect(
        isHermesSteerAck('⏩ Steer queued for the active turn: hi'),
        isTrue,
      );
      expect(
        isHermesSteerAck(
          'No active turn — queued for the next turn. (1 queued)',
        ),
        isTrue,
      );
      expect(isHermesSteerAck('⚠️ Steer failed: no agent'), isTrue);
      expect(isHermesSteerAck("I'll look at the main file only."), isFalse);
    });

    test('only its own failure counts as a refusal — a message queued for the '
        'next turn is still a message Hermes has', () {
      expect(hermesSteerRefusal('⚠️ Steer failed: no agent'), isNotNull);
      expect(hermesSteerRefusal('Usage: /steer <guidance>'), isNotNull);
      expect(
        hermesSteerRefusal('⏩ Steer queued for the active turn: hi'),
        isNull,
      );
      expect(
        hermesSteerRefusal(
          'No active turn — queued for the next turn. (1 queued)',
        ),
        isNull,
      );
    });
  });

  group('the way into a turn that is already running', () {
    test('a chat is steerable only while its turn holds the channel open', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final steering = container.read(agentSteeringProvider.notifier);

      expect(container.read(canSteerChatProvider('chat-1')), isFalse);
      steering.offer('chat-1', (text) async => null);
      expect(container.read(canSteerChatProvider('chat-1')), isTrue);
      // Another chat's turn is another chat's business.
      expect(container.read(canSteerChatProvider('chat-2')), isFalse);

      steering.withdraw('chat-1');
      expect(container.read(canSteerChatProvider('chat-1')), isFalse);
    });

    test(
      'the message goes to the turn running in the chat it was typed in',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final steering = container.read(agentSteeringProvider.notifier);
        final one = <String>[];
        final two = <String>[];
        steering.offer('chat-1', (text) async {
          one.add(text);
          return null;
        });
        steering.offer('chat-2', (text) async {
          two.add(text);
          return null;
        });

        expect(await steering.steer('chat-2', 'stop after the tests'), isTrue);
        expect(one, isEmpty);
        expect(two, ['stop after the tests']);
      },
    );

    test('an agent that would not take it says so in the log, and the caller '
        'is told to queue it instead', () async {
      final log = _RecordingLog();
      final container = ProviderContainer(
        overrides: [appLogProvider.overrideWithValue(log)],
      );
      addTearDown(container.dispose);
      final steering = container.read(agentSteeringProvider.notifier);
      steering.offer(
        'chat-1',
        (text) async => 'The turn had already finished.',
      );

      expect(await steering.steer('chat-1', 'and use the other file'), isFalse);
      // The user is told nothing — their message simply waits — so the reason
      // has to survive somewhere a channel that stopped working can be seen.
      expect(log.lines.single, contains('The turn had already finished.'));
    });

    test('with no turn running there is nothing to take it', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        await container
            .read(agentSteeringProvider.notifier)
            .steer('chat-1', 'hello?'),
        isFalse,
      );
    });
  });
}
