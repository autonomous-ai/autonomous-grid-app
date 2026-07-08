import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

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

/// A [ChatSender] that replays canned updates and records what it was asked to
/// send — no live relay involved.
class _FakeSender implements ChatSender {
  _FakeSender(this.updates);
  final List<ChatSendUpdate> updates;
  List<ChatMessage>? history;
  String? model;
  PlaygroundModality? modality;

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
  }) {
    this.history = history;
    this.model = model;
    this.modality = modality;
    return Stream.fromIterable(updates);
  }
}

/// A controller wired to a temp-dir store and a fake sender.
({ProviderContainer container, ChatStore store, _FakeSender sender}) _harness(
  Directory dir, {
  required List<ChatSendUpdate> updates,
}) {
  final store = ChatStore(directory: dir);
  final sender = _FakeSender(updates);
  final container = ProviderContainer(overrides: [
    chatStoreProvider.overrideWithValue(store),
    chatSenderProvider.overrideWithValue(sender),
  ]);
  addTearDown(container.dispose);
  return (container: container, store: store, sender: sender);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_chat_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  test('send creates a conversation, appends the reply and persists it',
      () async {
    final h = _harness(tmp, updates: [
      const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'hi back')),
    ]);

    await h.container.read(chatSessionsProvider.notifier).send(
          network: _credential(),
          model: 'qwen',
          message: 'hi',
        );

    final state = h.container.read(chatSessionsProvider);
    expect(state.sending, isFalse);
    expect(state.error, isNull);
    expect(state.conversations, hasLength(1));

    final conv = state.conversations.single;
    expect(state.activeId, conv.id);
    expect(conv.model, 'qwen');
    expect(conv.title, 'hi');
    expect(conv.messages.map((m) => m.role).toList(),
        [ChatRole.user, ChatRole.assistant]);
    expect(conv.messages.last.text, 'hi back');

    // The sender saw the running history (with the user turn appended).
    expect(h.sender.history!.single.text, 'hi');

    // Persisted to disk and reloadable.
    final reloaded = ChatStore(directory: tmp).loadAll();
    expect(reloaded, hasLength(1));
    expect(reloaded.single.messages.last.text, 'hi back');
  });

  test('a failure keeps the user message, sets the error and persists it',
      () async {
    final h = _harness(tmp, updates: [const ChatSendFailure('provider offline')]);

    await h.container.read(chatSessionsProvider.notifier).send(
          network: _credential(),
          model: 'qwen',
          message: 'hi',
        );

    final state = h.container.read(chatSessionsProvider);
    expect(state.error, 'provider offline');
    expect(state.sending, isFalse);
    expect(state.conversations.single.messages, hasLength(1));
    expect(state.conversations.single.messages.single.role, ChatRole.user);

    final reloaded = ChatStore(directory: tmp).loadAll();
    expect(reloaded.single.messages.single.text, 'hi');
  });

  test('a second turn appends to the same open conversation', () async {
    final h = _harness(tmp, updates: [
      const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a1')),
    ]);
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(
        network: _credential(), model: 'm', message: 'q1');
    await controller.send(
        network: _credential(), model: 'm', message: 'q2');

    final state = h.container.read(chatSessionsProvider);
    expect(state.conversations, hasLength(1));
    expect(state.conversations.single.messages.map((m) => m.text).toList(),
        ['q1', 'a1', 'q2', 'a1']);
  });

  test('newChat starts a fresh compose without losing history', () async {
    final h = _harness(tmp, updates: [
      const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
    ]);
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(network: _credential(), model: 'm', message: 'q1');
    controller.newChat();

    var state = h.container.read(chatSessionsProvider);
    expect(state.activeId, isNull);
    expect(state.conversations, hasLength(1));

    // Sending now spawns a second conversation.
    await controller.send(network: _credential(), model: 'm', message: 'q2');
    state = h.container.read(chatSessionsProvider);
    expect(state.conversations, hasLength(2));
  });

  test('deleteConversation removes it from state and disk', () async {
    final h = _harness(tmp, updates: [
      const ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: 'a')),
    ]);
    final controller = h.container.read(chatSessionsProvider.notifier);

    await controller.send(network: _credential(), model: 'm', message: 'q');
    final id = h.container.read(chatSessionsProvider).conversations.single.id;

    controller.deleteConversation(id);

    final state = h.container.read(chatSessionsProvider);
    expect(state.conversations, isEmpty);
    expect(state.activeId, isNull);
    expect(ChatStore(directory: tmp).loadAll(), isEmpty);
  });

  test('loads saved conversations on build and opens the newest', () async {
    final store = ChatStore(directory: tmp);
    store.save(Conversation(
      id: 'old',
      title: 'Older one',
      model: 'm',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      messages: const [ChatMessage(role: ChatRole.user, text: 'hey')],
    ));
    store.save(Conversation(
      id: 'new',
      title: 'Newer one',
      model: 'm',
      createdAt: DateTime(2026, 6, 1),
      updatedAt: DateTime(2026, 6, 1),
    ));

    final container = ProviderContainer(overrides: [
      chatStoreProvider.overrideWithValue(store),
      chatSenderProvider.overrideWithValue(_FakeSender(const [])),
    ]);
    addTearDown(container.dispose);

    final state = container.read(chatSessionsProvider);
    expect(state.conversations, hasLength(2));
    expect(state.activeId, 'new'); // newest-first
  });
}
