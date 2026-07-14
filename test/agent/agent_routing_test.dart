import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_routing.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';

void main() {
  group('agentAnswersTurn', () {
    test('plain text goes through the agent — the default', () {
      expect(
        agentAnswersTurn(
          modality: PlaygroundModality.text,
          hasAttachments: false,
          agentInstalled: true,
        ),
        isTrue,
      );
    });

    test('image and video go straight to the API (the agent is text-only)', () {
      for (final modality in [
        PlaygroundModality.image,
        PlaygroundModality.video,
      ]) {
        expect(
          agentAnswersTurn(
            modality: modality,
            hasAttachments: false,
            agentInstalled: true,
          ),
          isFalse,
          reason: '$modality must not be swallowed by the agent',
        );
      }
    });

    test('a text turn carrying an image goes to the API — the agent is blind '
        'to attachments', () {
      expect(
        agentAnswersTurn(
          modality: PlaygroundModality.text,
          hasAttachments: true,
          agentInstalled: true,
        ),
        isFalse,
      );
    });

    test('with no agent installed, chat still answers — via the API', () {
      expect(
        agentAnswersTurn(
          modality: PlaygroundModality.text,
          hasAttachments: false,
          agentInstalled: false,
        ),
        isFalse,
      );
    });
  });
}
