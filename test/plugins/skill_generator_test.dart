import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_transport.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/plugins/logic/skill_generator.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';

/// A chat transport that answers with whatever the test scripts, and records
/// where it was pointed — no HTTP, no model.
class _FakeTransport implements ChatTransport {
  _FakeTransport({this.reply, this.error});

  final String? reply;
  final ChatTransportError? error;
  String? endpoint;
  String? model;
  String? apiKey;

  @override
  Future<ChatCompletion> complete({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    this.endpoint = endpoint;
    this.apiKey = apiKey;
    this.model = model;
    return (reply, null, error);
  }
}

void main() {
  group('parseGeneratedSkill', () {
    test('reads name, description and instructions from a clean object', () {
      final draft = parseGeneratedSkill(
        '{"name": "Weekly Report", '
        '"description": "Use when I ask for a status update.", '
        '"instructions": "1. Read the folder.\\n2. Write ten lines."}',
      );

      expect(draft, isNotNull);
      expect(draft!.name, 'Weekly Report');
      expect(draft.description, 'Use when I ask for a status update.');
      expect(draft.instructions, '1. Read the folder.\n2. Write ten lines.');
    });

    test('digs the object out of a code fence and surrounding prose', () {
      final draft = parseGeneratedSkill(
        'Sure! Here you go:\n```json\n'
        '{"name": "Tidy Inbox", "instructions": "Archive read mail."}\n'
        '```\nHope that helps.',
      );

      expect(draft, isNotNull);
      expect(draft!.name, 'Tidy Inbox');
      expect(draft.instructions, 'Archive read mail.');
      // Missing description is allowed — it just comes back empty.
      expect(draft.description, isEmpty);
    });

    test('rejects an answer missing the parts a skill needs', () {
      // No instructions — nothing for the assistant to actually do.
      expect(parseGeneratedSkill('{"name": "Half a skill"}'), isNull);
      // Not JSON at all.
      expect(parseGeneratedSkill('I could not do that.'), isNull);
    });
  });

  group('SkillGenerator.generate', () {
    ProviderContainer localContainer(_FakeTransport transport) {
      final container = ProviderContainer(
        overrides: [
          localProviderEndpointProvider.overrideWithValue(
            'http://localhost:8081',
          ),
          servingModelProvider.overrideWithValue('qwen3'),
          chatTransportProvider.overrideWithValue(transport),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('drafts against the local engine when one is serving', () async {
      final transport = _FakeTransport(
        reply:
            '{"name": "Weekly Report", "description": "Use when asked.", '
            '"instructions": "Summarise the week."}',
      );
      final container = localContainer(transport);

      final draft = await container
          .read(skillGeneratorProvider)
          .generate('weekly report');

      expect(draft.name, 'Weekly Report');
      expect(draft.instructions, 'Summarise the week.');
      // The local engine's own endpoint and model, not the relay.
      expect(transport.endpoint, 'http://localhost:8081/v1/chat/completions');
      expect(transport.model, 'qwen3');
    });

    test('turns a transport failure into a plain-language exception', () async {
      final transport = _FakeTransport(
        error: const ChatTransportError('engine on fire', statusCode: 500),
      );
      final container = localContainer(transport);

      expect(
        () => container.read(skillGeneratorProvider).generate('anything'),
        throwsA(
          isA<SkillGenerationException>().having(
            (e) => e.message,
            'message',
            contains('engine on fire'),
          ),
        ),
      );
    });

    test('an empty idea never reaches a model', () async {
      final transport = _FakeTransport(reply: '{}');
      final container = localContainer(transport);

      await expectLater(
        container.read(skillGeneratorProvider).generate('   '),
        throwsA(isA<SkillGenerationException>()),
      );
      expect(transport.endpoint, isNull);
    });

    test('says so when no model is ready to answer', () async {
      final container = ProviderContainer(
        overrides: [
          localProviderEndpointProvider.overrideWithValue(null),
          servingModelProvider.overrideWithValue(null),
          playgroundModelsProvider.overrideWithValue(const []),
          chatTransportProvider.overrideWithValue(_FakeTransport(reply: '{}')),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(skillGeneratorProvider).generate('anything'),
        throwsA(
          isA<SkillGenerationException>().having(
            (e) => e.message,
            'message',
            contains('No model is ready'),
          ),
        ),
      );
    });
  });
}
