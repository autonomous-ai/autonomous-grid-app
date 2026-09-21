import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/agent_steering.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_bot_controller.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_bot_store.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/infrastructure/api/telegram_bot_api.dart';
import 'package:grid_app/infrastructure/api/telegram_wire.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// The one person allowed to use the bot in these tests, and the chat they
/// message it from.
const int _kUser = 424242;
const int _kChat = 900900;

/// A message the bot is allowed to answer.
TelegramText _text(String body, {int id = 1, int from = _kUser}) =>
    TelegramText(
      updateId: id,
      chatId: _kChat,
      privateChat: true,
      fromId: from,
      fromName: 'Jacob',
      text: body,
      sentAt: DateTime.now(),
    );

/// A picture someone sent the bot, which its turn has to fetch before it can
/// do anything else with it.
TelegramText _photo({int id = 1}) => TelegramText(
  updateId: id,
  chatId: _kChat,
  privateChat: true,
  fromId: _kUser,
  fromName: 'Jacob',
  text: '',
  sentAt: DateTime.now(),
  pictureId: 'pic-1',
);

/// A tap on the [row]th button of the menu the bot last drew.
TelegramButtonPress _tap(String data, {int id = 2}) => TelegramButtonPress(
  updateId: id,
  callbackId: 'cb-$id',
  fromId: _kUser,
  chatId: _kChat,
  messageId: 100,
  data: data,
);

/// What the bot sent while answering a command.
typedef _Sent = ({int chat, String text, TelegramKeyboard rows});

/// Telegram, answered from memory: it hands the bot a canned list of updates
/// once and records everything the bot says back.
///
/// This is the seam [telegramBotApiProvider] exists for, and the only way these
/// commands can be run at all — the other end of a real one is a phone.
class _FakeApi implements TelegramBotApi {
  _FakeApi(this._updates);

  final List<TelegramUpdate> _updates;
  final List<_Sent> sent = [];
  final List<_Sent> edits = [];
  final List<String?> toasts = [];
  Map<String, String> commands = const {};

  /// The poll waiting on Telegram to say something — how a tap is delivered
  /// *after* the menu it taps has been drawn, which is the only order a phone
  /// can produce.
  Completer<List<TelegramUpdate>>? _waiting;
  int _nextMessage = 100;

  /// The last thing the bot put on the phone, sent or edited into place.
  _Sent get last => edits.isNotEmpty ? edits.last : sent.last;

  /// Hand the bot one more update, now.
  void deliver(TelegramUpdate update) {
    final waiting = _waiting;
    if (waiting == null || waiting.isCompleted) {
      _updates.add(update);
      return;
    }
    _waiting = null;
    waiting.complete([update]);
  }

  @override
  Future<TelegramBotIdentity> getMe() async =>
      (id: 1, username: 'grid_test_bot', name: 'Grid');

  @override
  Future<List<TelegramUpdate>> getUpdates({int? offset}) {
    if (_updates.isNotEmpty) {
      final batch = [..._updates];
      _updates.clear();
      return Future.value(batch);
    }
    return (_waiting = Completer()).future;
  }

  @override
  Future<int> sendMessage(
    int chatId,
    String text, {
    bool html = false,
    TelegramKeyboard rows = const [],
  }) async {
    sent.add((chat: chatId, text: text, rows: rows));
    return _nextMessage++;
  }

  @override
  Future<void> editMessage(
    int chatId,
    int messageId,
    String text, {
    bool html = false,
    TelegramKeyboard rows = const [],
  }) async => edits.add((chat: chatId, text: text, rows: rows));

  @override
  Future<void> sendTyping(int chatId) async {}

  @override
  Future<void> answerButton(String callbackId, {String? text}) async =>
      toasts.add(text);

  @override
  Future<void> setCommands(Map<String, String> commands) async =>
      this.commands = commands;

  @override
  Future<void> deleteWebhook() async {}

  /// Set to hold every picture download open — how a turn is kept in its
  /// *preparing* phase, where it is neither queued nor streaming yet, for as
  /// long as a test needs it there.
  Completer<TelegramFile>? holdDownloads;

  /// Every picture the bot has asked for — how a test tells "the turn reached
  /// its download" from "the turn hasn't started yet".
  final List<String> downloaded = [];

  @override
  Future<TelegramFile> downloadFile(String fileId) {
    downloaded.add(fileId);
    return holdDownloads?.future ??
        Future.error(const TelegramUnreachable('No files in these tests.'));
  }

  @override
  void close() {
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) waiting.complete(const []);
  }
}

NetworkCredential _grid() => const NetworkCredential(
  networkId: 'grid-1',
  name: 'Home grid',
  networkType: 'permissioned',
  lanSignalingUrl: 'https://grid.example/g1',
  accessToken: 'tok',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node',
  deviceId: 'dev',
  roles: [],
  scopes: [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

GridOverview _overview() => GridOverview.fromJson(const {
  'grid': {'state': 'active'},
  'stats': {'models': 0, 'nodes': 0},
  'models': [],
  'nodes': [],
});

/// A bot running against [updates], with the grid serving [served] — every
/// store pointed at a temp dir, nothing reaching Telegram or `~/.grid`.
({ProviderContainer container, _FakeApi api}) _bot(
  List<TelegramUpdate> updates, {
  List<String> served = const ['llama', 'qwen'],
}) {
  final dir = Directory.systemTemp.createTempSync('grid-telegram-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A write landing off-isolate; the temp dir is the OS's problem now.
    }
  });
  final api = _FakeApi(updates);
  final container = ProviderContainer(
    overrides: [
      telegramBotApiProvider.overrideWithValue((_) => api),
      telegramBotStoreProvider.overrideWithValue(
        TelegramBotStore(file: File('${dir.path}/telegram_bot.json')),
      ),
      chatStoreProvider.overrideWithValue(ChatStore(directory: dir)),
      chatPrefsStoreProvider.overrideWithValue(
        ChatPrefsStore(file: File('${dir.path}/chat_prefs.json')),
      ),
      projectsStoreProvider.overrideWithValue(
        ProjectsStore(file: File('${dir.path}/projects.json')),
      ),
      sessionProvider.overrideWithValue(
        CredentialsFile(networks: [_grid()], activeNetwork: 'grid-1'),
      ),
      // What the grid serves, the way the bot has to read it: a request that
      // answers a moment later, with nobody watching it.
      networkModelsForProvider.overrideWith((ref, id) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return served;
      }),
      gridOverviewForProvider.overrideWith((ref, id) async => _overview()),
      // No agent is installed, so nothing here can spawn one: a plain turn
      // would go to the grid itself, and the model rows stay the grid's.
      hermesPathProvider.overrideWithValue(null),
      codexPathProvider.overrideWithValue(null),
      claudePathProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, api: api);
}

/// Run the bot until [ready], or fail saying what it said instead — the bot
/// answers on its own time, and a command that never answers is the bug.
Future<void> _until(
  bool Function() ready, {
  required _FakeApi api,
  String what = 'an answer',
}) async {
  for (var i = 0; i < 400; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail(
    'the bot never sent $what — it sent '
    '${[for (final message in api.sent) message.text]}',
  );
}

/// Connect the bot and let it read its updates.
Future<void> _connect(ProviderContainer container) async {
  final failure = await container
      .read(telegramBotProvider.notifier)
      .connect(
        token: '8123456789:AAF-token-that-looks-real',
        userId: '$_kUser',
      );
  expect(failure, isNull);
}

void main() {
  test(
    '/start says what the bot can do, so a first message is never a guess',
    () async {
      final bot = _bot([_text('/start')]);

      await _connect(bot.container);
      await _until(() => bot.api.sent.isNotEmpty, api: bot.api);

      expect(bot.api.sent.single.text, contains('/sessions'));
      expect(bot.api.sent.single.text, contains('/model'));
    },
  );

  test('the / menu is re-sent on every start, so a bot connected before a '
      'command existed learns it', () async {
    final bot = _bot(const []);

    await _connect(bot.container);

    expect(bot.api.commands.keys, containsAll(['new', 'sessions', 'model']));
  });

  test('/model offers the models the grid serves — the list is waited for, so '
      'it is never just the rows that come from nowhere else', () async {
    final bot = _bot([_text('/model')]);

    await _connect(bot.container);
    await _until(() => bot.api.sent.isNotEmpty, api: bot.api, what: 'the menu');

    final menu = bot.api.sent.single;
    expect(menu.text, contains('Current model'));
    expect(
      [for (final row in menu.rows) row.single.label],
      // The one in use is ticked; with nothing picked anywhere that is the
      // first thing the grid serves, which is what the turn would use too.
      ['llama ✓', 'qwen'],
    );
  });

  test('/model with a name sets it there and then, without a menu', () async {
    final bot = _bot([_text('/model qwen')]);

    await _connect(bot.container);
    await _until(() => bot.api.sent.isNotEmpty, api: bot.api);

    expect(bot.api.sent.single.text, contains('Model set to'));
    expect(bot.api.sent.single.text, contains('qwen'));
    expect(bot.api.sent.single.rows, isEmpty);
  });

  test('/model with a name this grid does not serve says so rather than '
      'sending a turn nobody can answer', () async {
    final bot = _bot([_text('/model gpt-5')]);

    await _connect(bot.container);
    await _until(() => bot.api.sent.length > 1, api: bot.api);

    expect(bot.api.sent.first.text, contains("isn't serving"));
    expect(bot.api.sent.last.text, contains('Current model'));
  });

  test('/model on a grid serving nothing says so, instead of a menu of one '
      'row that came from somewhere else', () async {
    final bot = _bot([_text('/model')], served: const []);

    await _connect(bot.container);
    await _until(() => bot.api.sent.isNotEmpty, api: bot.api);

    expect(bot.api.sent.single.text, contains("isn't serving a model"));
    expect(bot.api.sent.single.rows, isEmpty);
  });

  test('/sessions asks for a project first, and lists every project with the '
      'chats outside them all', () async {
    final bot = _bot([_text('/sessions')]);
    bot.container
        .read(projectsProvider.notifier)
        .create(path: '/tmp/grid-test-project', name: 'Kho hàng');

    await _connect(bot.container);
    await _until(() => bot.api.sent.isNotEmpty, api: bot.api, what: 'the menu');

    final menu = bot.api.sent.single;
    expect(menu.text, contains('Where do you want to work?'));
    expect([
      for (final row in menu.rows) row.single.label,
    ], containsAll([contains('Chats (no project)'), contains('Kho hàng')]));
  });

  test('picking a project opens its chats in the same message, with a way '
      'back', () async {
    final bot = _bot([_text('/sessions')]);

    await _connect(bot.container);
    await _until(() => bot.api.sent.isNotEmpty, api: bot.api, what: 'the menu');
    bot.api.deliver(_tap('mp:1:0'));
    await _until(
      () => bot.api.edits.isNotEmpty,
      api: bot.api,
      what: 'the chats',
    );

    expect(bot.api.last.text, contains('Chats (no project)'));
    expect([
      for (final row in bot.api.last.rows) row.single.label,
    ], containsAll([contains('New chat here'), contains('All projects')]));
  });

  test('a button from a menu that has been replaced does nothing, so a stale '
      'tap never picks the wrong chat', () async {
    final bot = _bot([_text('/sessions')]);

    await _connect(bot.container);
    await _until(() => bot.api.sent.isNotEmpty, api: bot.api, what: 'the menu');
    bot.api.deliver(_tap('mp:99:0'));
    await _until(
      () => bot.api.toasts.isNotEmpty,
      api: bot.api,
      what: 'a toast',
    );

    expect(bot.api.toasts.single, 'Expired, run it again');
    expect(bot.api.edits, isEmpty);
  });

  test('/new starts a chat and says where it starts', () async {
    final bot = _bot([_text('/new')]);

    await _connect(bot.container);
    await _until(() => bot.api.sent.isNotEmpty, api: bot.api);

    expect(bot.api.sent.single.text, contains('New chat ready'));
  });

  test('/stop with nothing running says so, rather than answering a command '
      'with silence', () async {
    final bot = _bot([_text('/stop')]);

    await _connect(bot.container);
    await _until(() => bot.api.sent.isNotEmpty, api: bot.api);

    expect(bot.api.sent.single.text, contains('Nothing is being written'));
  });

  test('a command from anyone but the listed user is answered with nothing at '
      'all', () async {
    final bot = _bot([_text('/sessions', from: 99)]);

    await _connect(bot.container);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(bot.api.sent, isEmpty);
  });

  test('a permission question in a chat /sessions pointed a phone at still '
      'reaches that phone, because chatIdOf works the other way too', () async {
    final bot = _bot(const []);

    await _connect(bot.container);
    // /sessions on a desktop chat leaves no telegram- prefix in its id; only
    // the thread map knows it is a Telegram chat carrying on there.
    await bot.container
        .read(telegramBotProvider.notifier)
        .point(_kChat, 'a-desktop-chat-id');

    expect(
      bot.container
          .read(telegramBotProvider.notifier)
          .chatIdOf('a-desktop-chat-id'),
      _kChat,
    );
  });

  test('/stop while the turn is still fetching a picture says it stopped — a '
      'command answered with silence reads as one that never ran', () async {
    final bot = _bot([_photo()]);
    // The turn will sit in the download until this is completed, which is where
    // a /stop has nothing streaming yet to stop.
    bot.api.holdDownloads = Completer();

    await _connect(bot.container);
    await _until(
      () => bot.api.downloaded.isNotEmpty,
      api: bot.api,
      what: 'a turn that reached its picture',
    );
    bot.api.deliver(_text('/stop', id: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // The picture arrives after the stop, as a slow one would: the turn carries
    // on to the next thing it does, which is where it has to notice.
    bot.api.holdDownloads!.complete((
      name: 'shot.png',
      bytes: Uint8List.fromList([1, 2, 3]),
    ));
    await _until(
      () => bot.api.sent.any((m) => m.text.contains('Stopped')),
      api: bot.api,
      what: 'anything at all about the /stop',
    );

    expect(bot.api.sent.last.text, 'Stopped before it answered.');
  });

  test('a message sent while the assistant is still writing goes into that '
      'answer, instead of waiting behind it', () async {
    final bot = _bot(const []);
    bot.api.holdDownloads = Completer();

    await _connect(bot.container);
    // A chat to carry on in, and a picture to hold the turn open while the
    // second message arrives.
    await bot.container.read(telegramBotProvider.notifier).startNew(_kChat);
    final chat = bot.container
        .read(telegramBotProvider.notifier)
        .current(_kChat)!;
    // The way into a running turn that an agent would have offered as its turn
    // started — this harness installs no agent, so the test offers it.
    final steered = <String>[];
    bot.container.read(agentSteeringProvider.notifier).offer(chat, (
      text,
    ) async {
      steered.add(text);
      return null;
    });
    bot.api.deliver(_photo(id: 3));
    await _until(
      () => bot.api.downloaded.isNotEmpty,
      api: bot.api,
      what: 'a turn that reached its picture',
    );

    bot.api.deliver(_text('actually, just the main file', id: 4));
    await _until(
      () => steered.isNotEmpty,
      api: bot.api,
      what: 'a message handed to the running answer',
    );

    expect(steered.single, 'actually, just the main file');
    expect(
      bot.api.sent.last.text,
      'The assistant will read that while it '
      'works.',
    );
  });

  test('a picture sent while the assistant is writing waits its turn — no '
      'agent takes one mid-answer, so it must not read as delivered', () async {
    final bot = _bot(const []);
    bot.api.holdDownloads = Completer();

    await _connect(bot.container);
    await bot.container.read(telegramBotProvider.notifier).startNew(_kChat);
    final chat = bot.container
        .read(telegramBotProvider.notifier)
        .current(_kChat)!;
    final steered = <String>[];
    bot.container.read(agentSteeringProvider.notifier).offer(chat, (
      text,
    ) async {
      steered.add(text);
      return null;
    });
    bot.api.deliver(_photo(id: 3));
    await _until(
      () => bot.api.downloaded.isNotEmpty,
      api: bot.api,
      what: 'a turn that reached its picture',
    );

    bot.api.deliver(_photo(id: 4));
    await _until(
      () => bot.api.sent.any((m) => m.text.contains('next')),
      api: bot.api,
      what: 'a picture told it was waiting',
    );

    expect(steered, isEmpty);
    expect(
      bot.api.sent.last.text,
      'Still on your last message — this one is '
      'next.',
    );
  });
}
