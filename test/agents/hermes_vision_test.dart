import 'package:grid_app/core/agent_homes.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/acp_images.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_routing.dart';
import 'package:grid_app/features/agents/logic/hermes_vision_controller.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/cli/hermes_vision_policy.dart';

void main() {
  group('which models the picker offers', () {
    PlaygroundModelOption option(
      String id, {
      bool vision = true,
      PlaygroundModality modality = PlaygroundModality.text,
    }) => PlaygroundModelOption(
      id: id,
      label: id,
      modality: modality,
      vision: vision,
    );

    test('a model that says it reads images', () {
      expect(visionCapableModels([option('Qwen/Qwen3.8-27B')]), [
        'Qwen/Qwen3.8-27B',
      ]);
    });

    test('never one that says it does not — the turn would fail at the engine, '
        'several messages later, as an error about a message it cannot '
        'parse', () {
      expect(
        visionCapableModels([option('text-only', vision: false)]),
        isEmpty,
      );
    });

    test('nor a media mode — those take a picture through their own endpoint, '
        'and none of them is something Hermes can be pointed at', () {
      expect(
        visionCapableModels([
          option('Image', modality: PlaygroundModality.image),
        ]),
        isEmpty,
      );
    });

    test('the id is offered exactly as the grid spells it, because this one is '
        'sent rather than shown', () {
      // The folded spelling is what every *count* in the app is keyed by, and
      // it is the one the relay refuses: asking for `qwen/qwen3.8-27b` comes
      // back 503 while `Qwen/Qwen3.8-27B` answers. A picker that offered the
      // folded form would write a model into Hermes's config that cannot be
      // routed to.
      expect(
        visionCapableModels([option('Qwen/Qwen3.8-27B')]).single,
        isNot('qwen/qwen3.8-27b'),
      );
    });
  });

  group('what lands in the Hermes config', () {
    late Directory home;
    setUp(() async {
      home = await Directory.systemTemp.createTemp('grid_vision_test');
    });
    tearDown(() => home.delete(recursive: true));

    File config() => File('${AgentHomes.hermesProfile(home.path)}/config.yaml');

    test('a config that has never mentioned auxiliary models still gets the '
        'whole block — every fresh install is that config', () async {
      // `upsert` fills one absent level and this path is two deep, so a naive
      // write throws on the machine where it matters most.
      await HermesVisionPolicy(
        home: home.path,
      ).write(model: 'Qwen/Qwen3.8-27B', provider: 'grid-3378218621364f16');

      final text = config().readAsStringSync();
      expect(text, contains('auxiliary:'));
      expect(text, contains('vision:'));
      expect(text, contains('model: Qwen/Qwen3.8-27B'));
      expect(text, contains('provider: grid-3378218621364f16'));
    });

    test('the rest of the config is left alone — Grid owns two keys in a file '
        'the user and the app both write', () async {
      await config().parent.create(recursive: true);
      await config().writeAsString('model:\n  default: my-model\n');

      await HermesVisionPolicy(
        home: home.path,
      ).write(model: 'Qwen/Qwen3.8-27B', provider: 'grid-1');

      final text = config().readAsStringSync();
      expect(text, contains('default: my-model'));
      expect(text, contains('model: Qwen/Qwen3.8-27B'));
    });

    test('reading it back is what the screen shows — the config is the store, '
        'so the choice survives the app closing', () async {
      final policy = HermesVisionPolicy(home: home.path);
      expect(await policy.read(), isNull, reason: 'nothing chosen yet');

      await policy.write(model: 'Qwen/Qwen3.8-27B', provider: 'grid-1');

      expect(
        await HermesVisionPolicy(home: home.path).read(),
        'Qwen/Qwen3.8-27B',
      );
    });

    test('clearing takes the provider with it — a provider left pointing at a '
        'grid with no model beside it is a half-setting', () async {
      final policy = HermesVisionPolicy(home: home.path);
      await policy.write(model: 'Qwen/Qwen3.8-27B', provider: 'grid-1');

      await policy.clear();

      final text = config().readAsStringSync();
      expect(await policy.read(), isNull);
      expect(text, isNot(contains('grid-1')));
    });
  });

  group('who receives a picture attached to a chat', () {
    test('Hermes does, once it has been given a model for images', () {
      expect(
        agentReadsImagesForChat(
          agent: AgentTool.hermes,
          hermesVisionModel: 'qwen/qwen3.8-27b',
          developerMode: true,
        ),
        isTrue,
      );
    });

    test('not while it is still on its own default — the app would be '
        'unlocking a turn it has no reason to believe works', () {
      expect(
        agentReadsImagesForChat(
          agent: AgentTool.hermes,
          hermesVisionModel: null,
          developerMode: true,
        ),
        isFalse,
      );
    });

    test(
      'and not the other agents — neither swaps an image for a description '
      'the way Hermes does, so the picture still needs a model that sees',
      () {
        for (final agent in [AgentTool.codex, AgentTool.claude]) {
          expect(
            agentReadsImagesForChat(
              agent: agent,
              hermesVisionModel: 'qwen/qwen3.8-27b',
              developerMode: true,
            ),
            isFalse,
            reason: agent.name,
          );
        }
      },
    );

    test('never in a shipped build — the setting that arms it is not there to '
        'be turned off', () {
      expect(
        agentReadsImagesForChat(
          agent: AgentTool.hermes,
          hermesVisionModel: 'qwen/qwen3.8-27b',
          developerMode: false,
        ),
        isFalse,
      );
    });
  });

  group('where a turn carrying a picture is sent', () {
    test('to the agent when it can read it', () {
      expect(
        agentAnswersTurn(
          modality: PlaygroundModality.text,
          hasAttachments: true,
          agentInstalled: true,
          agentReadsImages: true,
        ),
        isTrue,
      );
    });

    test('to the grid when it cannot — the old behaviour, unchanged for '
        'everyone who has not set a model for images', () {
      expect(
        agentAnswersTurn(
          modality: PlaygroundModality.text,
          hasAttachments: true,
          agentInstalled: true,
        ),
        isFalse,
      );
    });

    test('making a picture still never goes to the agent, whatever it can '
        'read — that is the grid\'s job, not an agent\'s', () {
      expect(
        agentAnswersTurn(
          modality: PlaygroundModality.image,
          hasAttachments: true,
          agentInstalled: true,
          agentReadsImages: true,
        ),
        isFalse,
      );
    });
  });

  group('the picture on the wire', () {
    test('rides as base64 with the type its name implies', () {
      final images = acpImages([
        MediaAttachment(
          filename: 'shot.jpg',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ]);

      expect(images.single.mimeType, 'image/jpeg');
      expect(images.single.base64, base64Encode([1, 2, 3]));
    });

    test('a name that says nothing falls to PNG — the same default Hermes '
        'applies, so the two ends never disagree', () {
      expect(imageMimeType('pasted'), 'image/png');
      expect(imageMimeType('shot.PNG'), 'image/png');
      expect(imageMimeType('photo.heic'), 'image/heic');
    });
  });
}
