import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_resume_point.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/features/playground/logic/chat_controller.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/infrastructure/api/chat_transport.dart';
import 'package:grid_app/features/playground/logic/media_outputs.dart';
import 'package:grid_app/features/playground/logic/media_transport.dart';
import 'package:grid_app/features/playground/logic/message_media.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/api/models/media_event.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// A stub relay signalling URL, so `relayBaseUrl` is `.../relay/v1`.
NetworkCredential _credential() => const NetworkCredential(
  networkId: 'net',
  name: 'Test grid',
  networkType: 'permissioned',
  lanSignalingUrl: 'https://grid.example/g1',
  accessToken: 'tok',
  refreshToken: '',
  email: '',
  nodeId: '',
  deviceId: '',
  roles: [],
  scopes: [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

class _FakeChatTransport implements ChatTransport {
  _FakeChatTransport(this.reply, this.error);
  final String? reply;
  final ChatTransportError? error;
  String? endpoint;
  List<Map<String, dynamic>>? messages;

  @override
  Stream<ChatStreamEvent> stream({
    String? turnId,
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    String? conversationId,
  }) async* {
    this.endpoint = endpoint;
    this.messages = messages;
    if (error != null) {
      yield ChatFailed(error!);
      return;
    }
    if (reply != null && reply!.isNotEmpty) yield ChatDelta(reply!);
    yield const ChatDone();
  }
}

/// Streams a scripted sequence of text deltas, then a clean finish — the shape
/// a real relay's SSE arrives in.
class _DeltaTransport implements ChatTransport {
  _DeltaTransport(this.deltas);
  final List<String> deltas;

  @override
  Stream<ChatStreamEvent> stream({
    String? turnId,
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    String? conversationId,
  }) async* {
    for (final delta in deltas) {
      yield ChatDelta(delta);
    }
    yield const ChatDone();
  }
}

class _FakeMediaTransport implements MediaTransport {
  _FakeMediaTransport(this.events);
  final List<MediaEvent> events;
  String? url;
  Map<String, dynamic>? payload;

  @override
  Stream<MediaEvent> stream({
    required String url,
    required String apiKey,
    required Map<String, dynamic> payload,
  }) {
    this.url = url;
    this.payload = payload;
    return Stream.fromIterable(events);
  }
}

ProviderContainer _container({
  ChatTransport? chat,
  MediaTransport? media,
  Directory? outputs,
}) {
  final container = ProviderContainer(
    overrides: [
      if (chat != null) chatTransportProvider.overrideWithValue(chat),
      if (media != null) mediaTransportProvider.overrideWithValue(media),
      if (outputs != null) mediaOutputsDirProvider.overrideWithValue(outputs),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

MediaFile _file(String name, List<int> bytes) =>
    MediaFile(filename: name, contentBase64: base64.encode(bytes));

/// A [ChatSender] whose stream stays open until the test drives it, so a send
/// can be left mid-flight to exercise cancellation.
class _OpenStreamSender implements ChatSender {
  final controller = StreamController<ChatSendUpdate>();

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    String? workdir,
    String? conversationId,
    String? instructions,
    bool planFirst = false,
    AgentApprovalMode? approval,
    String? turnId,
    AgentResumePoint? resume,
  }) => controller.stream;
}

void main() {
  group('text chat over HTTP', () {
    test(
      'appends the reply and hits {relayBaseUrl}/chat/completions',
      () async {
        final chat = _FakeChatTransport('hello there', null);
        final container = _container(chat: chat);

        await container
            .read(chatControllerProvider.notifier)
            .send(network: _credential(), model: 'm', message: 'hi');

        final state = container.read(chatControllerProvider);
        expect(state.sending, isFalse);
        expect(state.error, isNull);
        expect(state.messages.map((m) => m.role).toList(), [
          ChatRole.user,
          ChatRole.assistant,
        ]);
        expect(state.messages.last.text, 'hello there');
        expect(
          chat.endpoint,
          'https://grid.example/g1/relay/v1/chat/completions',
        );
      },
    );

    test('the reply arrives token by token, then commits whole', () async {
      // The relay chat streams now: a slow model fills the bubble as it goes,
      // through SendStreaming phases, before the finished turn appends.
      final container = _container(
        chat: _DeltaTransport(const ['The ', 'Honda ', 'CR-V']),
      );

      final streamed = <String>[];
      container.listen(chatControllerProvider, (_, next) {
        if (next.phase case SendStreaming(:final text)) streamed.add(text);
      });

      await container
          .read(chatControllerProvider.notifier)
          .send(network: _credential(), model: 'm', message: 'hi');

      // Each phase carried the whole answer so far — cumulative, not per-token.
      expect(streamed, ['The ', 'The Honda ', 'The Honda CR-V']);
      final state = container.read(chatControllerProvider);
      expect(state.messages.last.text, 'The Honda CR-V');
      expect(state.sending, isFalse);
    });

    test('surfaces a transport error and keeps the user message', () async {
      final chat = _FakeChatTransport(
        null,
        const ChatTransportError('no provider available', statusCode: 503),
      );
      final container = _container(chat: chat);

      await container
          .read(chatControllerProvider.notifier)
          .send(network: _credential(), model: 'm', message: 'hi');

      final state = container.read(chatControllerProvider);
      expect(state.error, contains('no provider'));
      expect(state.messages, hasLength(1));
      expect(state.messages.single.role, ChatRole.user);
    });

    test('maps insufficient balance to a top-up message', () async {
      final chat = _FakeChatTransport(
        null,
        const ChatTransportError(
          'Insufficient balance. Balance: 0.0',
          statusCode: 402,
        ),
      );
      final container = _container(chat: chat);

      await container
          .read(chatControllerProvider.notifier)
          .send(network: _credential(), model: 'm', message: 'hi');

      final state = container.read(chatControllerProvider);
      expect(state.error, contains('credit'));
      expect(state.error, isNot(contains('Insufficient balance')));
    });

    test(
      'vision: a text chat with an attached image sends image_url content',
      () async {
        final tmp = await Directory.systemTemp.createTemp('grid_media_test');
        addTearDown(() => tmp.delete(recursive: true));
        final chat = _FakeChatTransport('looks like a cat', null);
        final container = _container(chat: chat, outputs: tmp);

        await container
            .read(chatControllerProvider.notifier)
            .send(
              network: _credential(),
              model: 'vision',
              message: 'what is this?',
              attachments: [
                MediaAttachment(
                  filename: 'pic.png',
                  bytes: Uint8List.fromList([1, 2, 3]),
                ),
              ],
            );

        // The user turn rendered with the saved image, and the reply appended.
        final state = container.read(chatControllerProvider);
        expect(state.messages.first.media, hasLength(1));
        expect(state.messages.first.media.single.kind, MediaKind.image);
        expect(state.messages.last.text, 'looks like a cat');

        // The transport got OpenAI vision content: a text part + an image_url.
        final userMsg = chat.messages!.firstWhere((m) => m['role'] == 'user');
        final content = userMsg['content'] as List;
        expect(
          content.any(
            (p) => p['type'] == 'text' && p['text'] == 'what is this?',
          ),
          isTrue,
        );
        final imagePart =
            content.firstWhere((p) => p['type'] == 'image_url') as Map;
        expect(
          (imagePart['image_url'] as Map)['url'],
          startsWith('data:image/png;base64,'),
        );
      },
    );

    test(
      'a picture sent to a text-only model reads as "can\'t read images"',
      () async {
        final tmp = await Directory.systemTemp.createTemp('grid_media_test');
        addTearDown(() => tmp.delete(recursive: true));
        // A text model handed image parts answers a plain 400 — no per-model
        // "can see images" flag exists to check before sending, so this is the
        // shape the user actually hits.
        final chat = _FakeChatTransport(
          null,
          const ChatTransportError(
            'Invalid request: image input',
            statusCode: 400,
          ),
        );
        final container = _container(chat: chat, outputs: tmp);

        await container
            .read(chatControllerProvider.notifier)
            .send(
              network: _credential(),
              model: 'ds4f',
              message: 'what is this?',
              attachments: [
                MediaAttachment(
                  filename: 'pic.png',
                  bytes: Uint8List.fromList([1, 2, 3]),
                ),
              ],
            );

        final error = container.read(chatControllerProvider).error!;
        expect(error, contains("can't read images"));
        // The cryptic backend wording never reaches the user.
        expect(error.toLowerCase(), isNot(contains('invalid request')));
      },
    );

    test('a 5xx on an image turn is not blamed on vision', () async {
      // A grid with no provider is a different problem — telling the user to
      // remove their picture would send them fixing the wrong thing.
      final tmp = await Directory.systemTemp.createTemp('grid_media_test');
      addTearDown(() => tmp.delete(recursive: true));
      final chat = _FakeChatTransport(
        null,
        const ChatTransportError('no provider available', statusCode: 503),
      );
      final container = _container(chat: chat, outputs: tmp);

      await container
          .read(chatControllerProvider.notifier)
          .send(
            network: _credential(),
            model: 'ds4f',
            message: 'what is this?',
            attachments: [
              MediaAttachment(
                filename: 'pic.png',
                bytes: Uint8List.fromList([1, 2, 3]),
              ),
            ],
          );

      final error = container.read(chatControllerProvider).error!;
      expect(error, isNot(contains('read images')));
      expect(error, contains('no provider'));
    });

    test('maps a 401 to a sign-in prompt', () async {
      final chat = _FakeChatTransport(
        null,
        const ChatTransportError('unauthorized', statusCode: 401),
      );
      final container = _container(chat: chat);

      await container
          .read(chatControllerProvider.notifier)
          .send(network: _credential(), model: 'm', message: 'hi');

      expect(container.read(chatControllerProvider).error, contains('sign in'));
    });
  });

  group('media generation over HTTP', () {
    test(
      'image: streams to media/image/generate and saves the result',
      () async {
        final tmp = await Directory.systemTemp.createTemp('grid_media_test');
        addTearDown(() => tmp.delete(recursive: true));
        final media = _FakeMediaTransport([
          const MediaProgress(progress: 50, status: 'running'),
          MediaResult([
            _file('out.png', [1, 2, 3]),
          ]),
        ]);
        final container = _container(media: media, outputs: tmp);

        await container
            .read(chatControllerProvider.notifier)
            .send(
              network: _credential(),
              model: 'sdxl',
              message: 'a mug',
              modality: PlaygroundModality.image,
            );

        final state = container.read(chatControllerProvider);
        expect(state.error, isNull);
        expect(state.sending, isFalse);
        final assistant = state.messages.last;
        expect(assistant.role, ChatRole.assistant);
        expect(assistant.media, hasLength(1));
        expect(assistant.media.single.kind, MediaKind.image);
        expect(File(assistant.media.single.path).existsSync(), isTrue);
        expect(
          media.url,
          'https://grid.example/g1/relay/v1/media/image/generate',
        );
        expect(media.payload!['capability'], 'comfyui:image_generation');
        expect(media.payload!['prompt'], 'a mug');
      },
    );

    test('video without a starting image is blocked with guidance', () async {
      final media = _FakeMediaTransport(const []);
      final container = _container(media: media);

      await container
          .read(chatControllerProvider.notifier)
          .send(
            network: _credential(),
            model: 'i2v',
            message: 'pan slowly',
            modality: PlaygroundModality.video,
          );

      final state = container.read(chatControllerProvider);
      expect(state.error, contains('starting image'));
      expect(state.messages, hasLength(1));
      expect(media.url, isNull); // never dispatched
    });

    test('video with an attachment streams to media/video/i2v', () async {
      final tmp = await Directory.systemTemp.createTemp('grid_media_test');
      addTearDown(() => tmp.delete(recursive: true));
      final media = _FakeMediaTransport([
        MediaResult([
          _file('clip.mp4', [4, 5, 6]),
        ]),
      ]);
      final container = _container(media: media, outputs: tmp);

      await container
          .read(chatControllerProvider.notifier)
          .send(
            network: _credential(),
            model: 'i2v',
            message: 'pan slowly',
            modality: PlaygroundModality.video,
            attachments: [
              MediaAttachment(
                filename: 'seed.png',
                bytes: Uint8List.fromList([7, 8]),
              ),
            ],
          );

      final state = container.read(chatControllerProvider);
      expect(state.error, isNull);
      // The source image the user attached shows in their own turn…
      expect(state.messages.first.role, ChatRole.user);
      expect(state.messages.first.media.single.kind, MediaKind.image);
      // …and the generated clip in the assistant's.
      expect(state.messages.last.media.single.kind, MediaKind.video);
      expect(media.url, 'https://grid.example/g1/relay/v1/media/video/i2v');
      expect(media.payload!['capability'], 'comfyui:i2v');
      expect((media.payload!['input_image'] as Map)['filename'], 'seed.png');
    });

    test('a media error is surfaced and the user message is kept', () async {
      final media = _FakeMediaTransport([const MediaError('provider offline')]);
      final container = _container(media: media);

      await container
          .read(chatControllerProvider.notifier)
          .send(
            network: _credential(),
            model: 'sdxl',
            message: 'a mug',
            modality: PlaygroundModality.image,
          );

      final state = container.read(chatControllerProvider);
      expect(state.error, contains('provider offline'));
      expect(state.messages, hasLength(1));
    });
  });

  group('cancellation', () {
    test(
      'clear() cancels an in-flight send so a late reply cannot resurrect it',
      () async {
        final sender = _OpenStreamSender();
        final container = ProviderContainer(
          overrides: [chatSenderProvider.overrideWithValue(sender)],
        );
        addTearDown(container.dispose);
        final notifier = container.read(chatControllerProvider.notifier);

        // Start a send but keep the stream open — the dialog is "generating".
        final pending = notifier.send(
          network: _credential(),
          model: 'm',
          message: 'hi',
        );
        await Future<void>.delayed(Duration.zero); // let send() subscribe
        expect(container.read(chatControllerProvider).sending, isTrue);

        // The dialog closes → clear() must cancel the subscription.
        notifier.clear();
        expect(container.read(chatControllerProvider).messages, isEmpty);
        expect(container.read(chatControllerProvider).sending, isFalse);
        // send()'s future settles on cancel rather than hanging forever.
        await pending;

        // A reply that arrives after close must be dropped, not written back.
        sender.controller.add(
          const ChatSendSuccess(
            ChatMessage(role: ChatRole.assistant, text: 'late'),
          ),
        );
        await sender.controller.close();

        final state = container.read(chatControllerProvider);
        expect(state.messages, isEmpty);
        expect(state.sending, isFalse);
      },
    );
  });
}
