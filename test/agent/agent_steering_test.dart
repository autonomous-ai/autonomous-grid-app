import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/features/agents/logic/agent_steering.dart';
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
  group('what the user said mid-turn, in the turn', () {
    test('typed mid-sentence, it waits for the seam instead of cutting the '
        "agent's paragraph in half", () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final runs = container.read(agentRunsProvider.notifier);
      runs.reset('chat-1');

      // The agent is halfway through a sentence when the user cuts in.
      runs.interject(
        'chat-1',
        'just the main file',
        answer: 'Reading the repo (config,',
      );
      expect(
        container.read(agentRunProvider('chat-1')).parts,
        isEmpty,
        reason: 'nothing is placed while the sentence is still being written',
      );

      // It finishes the sentence and reaches for a tool: that is the seam, and
      // the message lands after the passage rather than inside it.
      runs.upsertStep(
        'chat-1',
        const AgentActivity(
          id: 'step-1',
          kind: AgentActivityKind.command,
          label: 'ls',
          status: AgentActivityStatus.running,
        ),
        answer: 'Reading the repo (config, main).',
      );

      expect(container.read(agentRunProvider('chat-1')).parts.map(_describe), [
        'text:Reading the repo (config, main).',
        'said:just the main file',
        'step:ls',
      ]);
    });

    test('typed while the agent is between blocks, it goes in at once — there '
        'is nothing to break', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final runs = container.read(agentRunsProvider.notifier);
      runs.reset('chat-1');
      runs.say('chat-1', 'Reading the repo.');

      runs.interject(
        'chat-1',
        'just the main file',
        answer: 'Reading the repo.',
      );

      expect(container.read(agentRunProvider('chat-1')).parts.map(_describe), [
        'text:Reading the repo.',
        'said:just the main file',
      ]);
    });

    test('a turn that ends while one is still waiting places it rather than '
        'losing it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final runs = container.read(agentRunsProvider.notifier);
      runs.reset('chat-1');
      runs.interject('chat-1', 'and stop there', answer: 'Working on it,');
      expect(container.read(agentRunProvider('chat-1')).spokenInto, isTrue);

      // What the landing does — see `_timelineOf`.
      runs.say('chat-1', 'Working on it, and stopping there.');

      expect(container.read(agentRunProvider('chat-1')).parts.map(_describe), [
        'text:Working on it, and stopping there.',
        'said:and stop there',
      ]);
    });

    test('an empty message is not a turn event', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(agentRunsProvider.notifier).interject('chat-1', '   ');

      expect(container.read(agentRunProvider('chat-1')).parts, isEmpty);
    });

    test(
      'survives being saved with the chat, and is worth saving even when the '
      'turn ran no steps at all',
      () {
        const said = TurnSaid('just the main file');
        final reloaded = turnPartFromJson(turnPartToJson(said));

        expect(reloaded, isA<TurnSaid>());
        expect((reloaded as TurnSaid).text, 'just the main file');
        // A turn that only talked still has a timeline when the user spoke into
        // it — otherwise their words are the one thing the message drops.
        expect(hasTimeline([const TurnText('hi'), said]), isTrue);
        expect(hasTimeline([const TurnText('hi')]), isFalse);
      },
    );
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

/// One part as `kind:text`, so a timeline reads as an ordered list in a test
/// failure rather than as three object hashes.
String _describe(TurnPart part) => switch (part) {
  TurnText(:final text) => 'text:$text',
  TurnSaid(:final text) => 'said:$text',
  TurnStep(:final step) => 'step:${step.label}',
};
