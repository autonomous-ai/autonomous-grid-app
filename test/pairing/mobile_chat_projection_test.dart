import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/grid_paths.dart';
import 'package:grid_app/infrastructure/pairing_host/mobile_chat_reader.dart';
import 'package:grid_app/infrastructure/pairing_host/mobile_rpc_service.dart';
import 'package:grid_app/infrastructure/pairing_host/mobile_upload_store.dart';
import 'package:grid_app/features/phone/logic/phone_chat_options.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// What the phone is served when it asks about chats and projects.
///
/// This is a wire format, not a screen: the projection is what a separately
/// shipped binary decodes, and the fields left *out* of it are a security
/// property rather than an omission (§8).
void main() {
  late Directory root;
  late Directory chats;

  setUp(() {
    root = Directory.systemTemp.createTempSync('grid-phone-projection');
    chats = Directory('${root.path}/chats')..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  void writeIndex(List<Map<String, Object?>> headers) {
    File(
      '${chats.path}/$kChatIndexName',
    ).writeAsStringSync(jsonEncode({'chats': headers}));
  }

  void writeChat(String id, List<Map<String, Object?>> messages) {
    File(
      '${chats.path}/$id.json',
    ).writeAsStringSync(jsonEncode({'id': id, 'messages': messages}));
  }

  group('the chat list', () {
    test(
      'comes back newest first, so the phone shows recent work at the top',
      () {
        writeIndex([
          {'id': 'a', 'title': 'older', 'updatedAt': '2026-09-01T00:00:00Z'},
          {'id': 'b', 'title': 'newest', 'updatedAt': '2026-09-14T00:00:00Z'},
          {'id': 'c', 'title': 'middle', 'updatedAt': '2026-09-07T00:00:00Z'},
        ]);

        final headers = readChatHeaders(chatsDir: chats);

        expect(headers.map((h) => h.title), ['newest', 'middle', 'older']);
      },
    );

    test('reads archived from the presence of archivedAt, which most chats '
        'do not carry at all', () {
      writeIndex([
        {'id': 'a', 'updatedAt': '2026-09-01T00:00:00Z'},
        {
          'id': 'b',
          'updatedAt': '2026-09-02T00:00:00Z',
          'archivedAt': '2026-09-03T00:00:00Z',
        },
      ]);

      final headers = readChatHeaders(chatsDir: chats);

      expect(headers.firstWhere((h) => h.id == 'a').archived, isFalse);
      expect(headers.firstWhere((h) => h.id == 'b').archived, isTrue);
    });

    test('is empty rather than throwing when Chat has never been opened, '
        'because a computer with no history is a normal state', () {
      expect(readChatHeaders(chatsDir: chats), isEmpty);
    });

    test(
      'survives a corrupt index instead of taking the channel down with it',
      () {
        File('${chats.path}/$kChatIndexName').writeAsStringSync('{not json');

        expect(readChatHeaders(chatsDir: chats), isEmpty);
      },
    );
  });

  group('a transcript page', () {
    List<Map<String, Object?>> turns(int count) => [
      for (var i = 0; i < count; i++)
        {'role': i.isEven ? 'user' : 'assistant', 'text': 'turn $i'},
    ];

    test(
      'ends at the newest turn, because that is what the phone opens on',
      () {
        writeChat('a', turns(100));

        final page = readChatPage('a', chatsDir: chats)!;

        expect(page.total, 100);
        expect(page.lines.last.text, 'turn 99');
        expect(page.lines.length, kMobileChatPageTurns);
        expect(page.offset, 100 - kMobileChatPageTurns);
      },
    );

    test('walks backwards by offset, so the phone can reach the start of a '
        'conversation the relay would refuse to send whole', () {
      writeChat('a', turns(100));

      final page = readChatPage('a', chatsDir: chats, offset: 0, limit: 10)!;

      expect(page.lines.first.text, 'turn 0');
      expect(page.lines.length, 10);
      expect(page.offset, 0);
    });

    test('stops on bytes as well as turns, since the frame limit is measured '
        'in bytes and ending a connection is how the relay enforces it', () {
      final long = 'x' * (kMobileChatPageBytes ~/ 4);
      writeChat('a', [
        for (var i = 0; i < 10; i++) {'role': 'assistant', 'text': long},
      ]);

      final page = readChatPage('a', chatsDir: chats, offset: 0)!;

      expect(page.lines.length, lessThan(10));
      expect(
        page.lines.fold<int>(0, (sum, line) => sum + line.text.length),
        lessThanOrEqualTo(kMobileChatPageBytes + long.length),
      );
    });

    test('still returns a single turn longer than the whole byte budget, '
        'because a page that stops before it holds anything never renders', () {
      writeChat('a', [
        {'role': 'assistant', 'text': 'y' * (kMobileChatPageBytes * 2)},
      ]);

      final page = readChatPage('a', chatsDir: chats)!;

      expect(page.lines, hasLength(1));
    });

    test('drops a turn that carried only a picture rather than showing an '
        'empty bubble that claims nothing was said', () {
      writeChat('a', [
        {
          'role': 'user',
          'text': '',
          'media': const [<String, Object?>{}],
        },
        {'role': 'assistant', 'text': 'here it is'},
      ]);

      final page = readChatPage('a', chatsDir: chats)!;

      expect(page.lines, hasLength(1));
      expect(page.lines.single.text, 'here it is');
    });

    test('is null for a chat this computer does not have, so the phone can '
        'say so instead of offering to send into a missing file', () {
      expect(readChatPage('nope', chatsDir: chats), isNull);
    });

    test('refuses an id that is a path, which is the one field the caller '
        'picks and the only way out of the chats folder', () {
      File(
        '${root.path}/secret.json',
      ).writeAsStringSync(jsonEncode({'messages': turns(1)}));

      expect(readChatPage('../secret', chatsDir: chats), isNull);
      expect(readChatPage('/etc/passwd', chatsDir: chats), isNull);
    });
  });

  group('the project list', () {
    test('never carries a project path: the phone picks projects by name, and '
        'the path is this computer filesystem layout', () {
      final file = File('${root.path}/projects.json')
        ..writeAsStringSync(
          jsonEncode([
            {
              'id': '1',
              'name': 'GroupMe',
              'path': '/Users/someone/WorkPlace/GroupMe',
              'model': 'auto',
              'agent': 'claude',
            },
          ]),
        );

      final projects = readProjectSummaries(file: file);

      expect(projects.single.name, 'GroupMe');
      expect(projects.single.toString(), isNot(contains('WorkPlace')));
    });

    test(
      'skips an entry with no id, since the phone addresses projects by it',
      () {
        final file = File('${root.path}/projects.json')
          ..writeAsStringSync(
            jsonEncode([
              {'name': 'nameless'},
              {'id': '2', 'name': 'real'},
            ]),
          );

        expect(readProjectSummaries(file: file).map((p) => p.name), ['real']);
      },
    );
  });

  group('what the service answers', () {
    MobileRpcService serviceOver({
      List<ChatHeader> chats = const [],
      List<ProjectSummary> projects = const [],
      ChatPage? page,
    }) => MobileRpcService(
      hostName: 'test-host',
      appVersion: '0.0.0',
      readGrids: () => const [],
      readChats: () => chats,
      readProjects: () => projects,
      readChat: (id, {int? limit, int? offset}) => page,
    );

    Future<MobileRpcResponse> ask(
      MobileRpcService service,
      String method, [
      Map<String, Object?> params = const {},
    ]) => service.handle(
      MobileRpcRequest(id: 'r1', method: method, params: params),
      deviceId: 'device-1',
    );

    test('refuses a method that is not on the allowlist, which is the security '
        'boundary rather than whatever the phone happens to render', () async {
      final answer = await ask(serviceOver(), 'files.read');

      expect(answer, isA<MobileRpcFailed>());
      expect((answer as MobileRpcFailed).code, 'forbidden');
    });

    test('says not_found for a chat this computer does not have, so the phone '
        'never opens a composer onto a missing conversation', () async {
      final answer = await ask(serviceOver(), 'chats.get', {'id': 'gone'});

      expect((answer as MobileRpcFailed).code, 'not_found');
    });

    test('says bad_request when no chat was named, which is a caller bug and '
        'not a missing chat', () async {
      final answer = await ask(serviceOver(), 'chats.get');

      expect((answer as MobileRpcFailed).code, 'bad_request');
    });

    test('carries total and offset back with a page, because they are how the '
        'phone knows there is more history to ask for', () async {
      final service = serviceOver(
        page: (
          lines: [(role: 'user', text: 'hello', index: 0, media: const [])],
          total: 500,
          offset: 460,
        ),
      );

      final answer = await ask(service, 'chats.get', {'id': 'c1'});

      expect(answer, isA<MobileRpcOk>());
      final result = (answer as MobileRpcOk).result;
      expect(result['total'], 500);
      expect(result['offset'], 460);
      // `index` rides along now: it is how the phone asks for a picture on this
      // turn, and it is the turn's place in the whole chat rather than in the
      // page — asserted here so a page that started numbering from its own
      // first row would fail loudly instead of fetching the wrong photo.
      expect(result['messages'], [
        {'role': 'user', 'text': 'hello', 'index': 0},
      ]);
    });

    test(
      'lists chats and projects with exactly the fields the phone is meant '
      'to see, so a field added upstream cannot leak by being forwarded',
      () async {
        final service = serviceOver(
          chats: [
            (
              id: 'c1',
              title: 'a chat',
              model: 'auto',
              agent: 'claude',
              projectId: 'p1',
              updatedAt: '2026-09-14T00:00:00Z',
              archived: false,
            ),
          ],
          projects: [
            (id: 'p1', name: 'GroupMe', model: 'auto', agent: 'claude'),
          ],
        );

        final chats = (await ask(service, 'chats.list') as MobileRpcOk).result;
        final projects =
            (await ask(service, 'projects.list') as MobileRpcOk).result;

        expect((chats['chats']! as List).single, {
          'id': 'c1',
          'title': 'a chat',
          'model': 'auto',
          'agent': 'claude',
          'projectId': 'p1',
          'updatedAt': '2026-09-14T00:00:00Z',
          'archived': false,
        });
        expect((projects['projects']! as List).single, {
          'id': 'p1',
          'name': 'GroupMe',
          'model': 'auto',
          'agent': 'claude',
        });
      },
    );
  });

  group('the gate on sending', () {
    final page = (
      lines: <ChatLine>[(role: 'user', text: 'hi', index: 0, media: const [])],
      total: 1,
      offset: 0,
    );
    var sent = <String>[];

    MobileRpcService hostThatCanSend() => MobileRpcService(
      hostName: 'test-host',
      appVersion: '0.0.0',
      readGrids: () => const [],
      readChat: (id, {int? limit, int? offset}) => page,
      sendToChat: (chatId, text, files) async {
        sent.add('$chatId:$text');
        return null;
      },
    );

    Future<MobileRpcResponse> send(
      MobileRpcService service, {
      required bool allowed,
      String text = 'do the thing',
    }) => service.handle(
      MobileRpcRequest(
        id: 'r1',
        method: 'chats.send',
        params: {'id': 'c1', 'text': text},
      ),
      deviceId: 'device-1',
      mayAct: () async => allowed,
    );

    setUp(() => sent = <String>[]);

    test('refuses a phone that has not been granted it, and nothing reaches '
        'the chat — this is the whole point of the switch', () async {
      final answer = await send(hostThatCanSend(), allowed: false);

      expect((answer as MobileRpcFailed).code, 'forbidden');
      expect(sent, isEmpty);
    });

    test('refuses when the caller never says whether the phone may act, so a '
        'host wired without thinking about it grants nothing', () async {
      final answer = await hostThatCanSend().handle(
        MobileRpcRequest(
          id: 'r1',
          method: 'chats.send',
          params: {'id': 'c1', 'text': 'do the thing'},
        ),
        deviceId: 'device-1',
      );

      expect((answer as MobileRpcFailed).code, 'forbidden');
      expect(sent, isEmpty);
    });

    test('says unavailable — not forbidden — on a host with no app behind it, '
        'because that is a different thing to go and fix', () async {
      final headless = MobileRpcService(
        hostName: 'test-host',
        appVersion: '0.0.0',
        readGrids: () => const [],
        readChat: (id, {int? limit, int? offset}) => page,
      );

      final answer = await send(headless, allowed: true);

      expect((answer as MobileRpcFailed).code, 'unavailable');
    });

    test('passes the message through once the switch is on', () async {
      final answer = await send(hostThatCanSend(), allowed: true);

      expect(answer, isA<MobileRpcOk>());
      expect((answer as MobileRpcOk).result['accepted'], true);
      expect(sent, ['c1:do the thing']);
    });

    test('refuses a message with nothing in it before the gate is even asked, '
        'so whitespace cannot start a turn', () async {
      final answer = await send(hostThatCanSend(), allowed: true, text: '   ');

      expect((answer as MobileRpcFailed).code, 'bad_request');
      expect(sent, isEmpty);
    });

    test('hands back the reason the computer could not start the turn, since '
        '"no grid signed in" is something the person can go and fix', () async {
      final service = MobileRpcService(
        hostName: 'test-host',
        appVersion: '0.0.0',
        readGrids: () => const [],
        readChat: (id, {int? limit, int? offset}) => page,
        sendToChat: (chatId, text, files) async => 'No model is running.',
      );

      final answer = await send(service, allowed: true);

      expect((answer as MobileRpcFailed).message, 'No model is running.');
    });

    test(
      'will not send into a chat this computer does not have, which would '
      'create the conversation the phone thought it was continuing',
      () async {
        final service = MobileRpcService(
          hostName: 'test-host',
          appVersion: '0.0.0',
          readGrids: () => const [],
          readChat: (id, {int? limit, int? offset}) => null,
          sendToChat: (chatId, text, files) async {
            sent.add(chatId);
            return null;
          },
        );

        final answer = await send(service, allowed: true);

        expect((answer as MobileRpcFailed).code, 'not_found');
        expect(sent, isEmpty);
      },
    );
  });

  group('the composer the phone is served', () {
    var changes = <String>[];
    var created = <String>[];

    MobileRpcService host() => MobileRpcService(
      hostName: 'test-host',
      appVersion: '0.0.0',
      readGrids: () => const [],
      readChat: (id, {int? limit, int? offset}) =>
          (lines: const <ChatLine>[], total: 0, offset: 0),
      readOptions: (chatId) async => {
        'model': {'selected': 'auto', 'options': []},
      },
      setOption: (chatId, field, value) async {
        changes.add('$chatId/$field=$value');
        return null;
      },
      createChat: (text, projectId, files) async {
        created.add('$projectId:$text');
        return (id: 'new-chat', problem: null);
      },
    );

    Future<MobileRpcResponse> ask(
      String method,
      Map<String, Object?> params, {
      required bool allowed,
    }) => host().handle(
      MobileRpcRequest(id: 'r1', method: method, params: params),
      deviceId: 'device-1',
      mayAct: () async => allowed,
    );

    setUp(() {
      changes = <String>[];
      created = <String>[];
    });

    test('lets any paired phone read the picks, because a composer that cannot '
        'draw its own pickers looks broken rather than locked', () async {
      final answer = await ask('chats.options', {'id': 'c1'}, allowed: false);

      expect(answer, isA<MobileRpcOk>());
    });

    test(
      'refuses to change a chat without the switch, since choosing the '
      'model and the access is arranging what the next turn may do',
      () async {
        final answer = await ask('chats.set', {
          'id': 'c1',
          'field': 'model',
          'value': 'auto',
        }, allowed: false);

        expect((answer as MobileRpcFailed).code, 'forbidden');
        expect(changes, isEmpty);
      },
    );

    test('refuses to start a chat without the switch', () async {
      final answer = await ask('chats.create', {
        'text': 'hello',
      }, allowed: false);

      expect((answer as MobileRpcFailed).code, 'forbidden');
      expect(created, isEmpty);
    });

    test('passes a change through once the switch is on', () async {
      final answer = await ask('chats.set', {
        'id': 'c1',
        'field': 'approval',
        'value': 'ask',
      }, allowed: true);

      expect(answer, isA<MobileRpcOk>());
      expect(changes, ['c1/approval=ask']);
    });

    test(
      'hands back the new chat id so the phone can open what it started',
      () async {
        final answer = await ask('chats.create', {
          'text': 'hello',
          'projectId': 'p1',
        }, allowed: true);

        expect((answer as MobileRpcOk).result['id'], 'new-chat');
        expect(created, ['p1:hello']);
      },
    );

    test('refuses a change with a field the phone made up, rather than '
        'forwarding it and hoping', () async {
      final answer = await ask('chats.set', {
        'id': 'c1',
        'value': 'auto',
      }, allowed: true);

      expect((answer as MobileRpcFailed).code, 'bad_request');
      expect(changes, isEmpty);
    });
  });

  group('which access levels a phone may set', () {
    test('every mode except full, which is the one that runs commands and '
        'changes files without asking', () {
      expect(phoneMaySetApproval(AgentApprovalMode.readOnly), isTrue);
      expect(phoneMaySetApproval(AgentApprovalMode.plan), isTrue);
      expect(phoneMaySetApproval(AgentApprovalMode.ask), isTrue);
      expect(phoneMaySetApproval(AgentApprovalMode.full), isFalse);
    });

    test(
      'the refusal is about the phone, not about the mode — a chat already '
      'on full still runs on it, the phone just cannot be what turned it on',
      () {
        // Stated as a test because the distinction is the whole design: this is
        // a rule against escalation from a pocket device, not a claim that full
        // access is unavailable.
        expect(kApprovalPhoneMayNotSet, AgentApprovalMode.full);
        expect(AgentApprovalMode.values, contains(AgentApprovalMode.full));
      },
    );
  });

  group('files a phone attaches', () {
    late Directory uploadRoot;
    var attached = <String>[];

    setUp(() {
      uploadRoot = Directory.systemTemp.createTempSync('grid-rpc-uploads');
      attached = <String>[];
    });

    tearDown(() => uploadRoot.deleteSync(recursive: true));

    MobileRpcService host() => MobileRpcService(
      hostName: 'test-host',
      appVersion: '0.0.0',
      readGrids: () => const [],
      readChat: (id, {int? limit, int? offset}) =>
          (lines: const <ChatLine>[], total: 0, offset: 0),
      uploads: MobileUploadStore(directory: uploadRoot),
      sendToChat: (chatId, text, files) async {
        attached.addAll(files.map((file) => file.name));
        return null;
      },
    );

    Future<MobileRpcResponse> ask(
      MobileRpcService service,
      String method,
      Map<String, Object?> params, {
      required bool allowed,
    }) => service.handle(
      MobileRpcRequest(id: 'r1', method: method, params: params),
      deviceId: 'device-1',
      mayAct: () async => allowed,
    );

    test('will not begin an upload without the switch — this is the one place '
        'a phone writes bytes to the computer', () async {
      final answer = await ask(host(), 'uploads.begin', {
        'name': 'photo.jpg',
        'size': 10,
      }, allowed: false);

      expect((answer as MobileRpcFailed).code, 'forbidden');
    });

    test('tells the phone how big a piece may be rather than letting it guess, '
        'because a frame too large ends the connection', () async {
      final answer = await ask(host(), 'uploads.begin', {
        'name': 'photo.jpg',
        'size': 10,
      }, allowed: true);

      final result = (answer as MobileRpcOk).result;
      expect(result['uploadId'], isA<String>());
      expect(result['chunkBytes'], maxChunkBytes);
    });

    test('carries a finished file into the turn it was sent with', () async {
      final service = host();
      final begun =
          (await ask(service, 'uploads.begin', {
                    'name': 'holiday.png',
                    'size': 3,
                  }, allowed: true)
                  as MobileRpcOk)
              .result['uploadId']!;
      await ask(service, 'uploads.chunk', {
        'uploadId': begun,
        'data': base64Encode(const [1, 2, 3]),
      }, allowed: true);

      final sent = await ask(service, 'chats.send', {
        'id': 'c1',
        'text': 'what is this',
        'uploads': [begun],
      }, allowed: true);

      expect(sent, isA<MobileRpcOk>());
      expect(attached.single, endsWith('.png'));
    });

    test('refuses the whole turn when a named file never finished, rather than '
        'answering about an attachment that is half there', () async {
      final service = host();
      final begun =
          (await ask(service, 'uploads.begin', {
                    'name': 'big.png',
                    'size': 100,
                  }, allowed: true)
                  as MobileRpcOk)
              .result['uploadId']!;

      final sent = await ask(service, 'chats.send', {
        'id': 'c1',
        'text': 'look',
        'uploads': [begun],
      }, allowed: true);

      expect(sent, isA<MobileRpcFailed>());
      expect(attached, isEmpty);
    });
  });

  group('a picture attached to a turn', () {
    late Directory root;
    late Directory chats;
    late File picture;

    setUp(() {
      root = Directory.systemTemp.createTempSync('grid-media');
      chats = Directory('${root.path}/chats')..createSync();
      picture = File('${root.path}/photo.jpg')
        ..writeAsBytesSync(List.generate(5000, (i) => i % 256));
      File('${chats.path}/c1.json').writeAsStringSync(
        jsonEncode({
          'id': 'c1',
          'messages': [
            {
              'role': 'user',
              'text': 'look at this',
              'media': [
                {'path': picture.path, 'kind': 'image'},
              ],
            },
          ],
        }),
      );
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('is described in the transcript without its bytes, because one photo '
        'can be bigger than a frame is allowed to be', () {
      final page = readChatPage('c1', chatsDir: chats)!;

      expect(page.lines.single.media.single.kind, 'image');
      expect(page.lines.single.media.single.name, 'photo.jpg');
    });

    test('comes back in slices that can be stitched into the whole file', () {
      final whole = <int>[];
      var offset = 0;
      while (true) {
        final slice = readChatMedia(
          'c1',
          messageIndex: 0,
          mediaIndex: 0,
          offset: offset,
          length: 1500,
          chatsDir: chats,
        )!;
        if (slice.bytes.isEmpty) break;
        whole.addAll(slice.bytes);
        offset += slice.bytes.length;
        if (offset >= slice.size) break;
      }

      expect(whole, picture.readAsBytesSync());
    });

    test('reports the whole file size on every slice, which is how the phone '
        'knows whether to ask again', () {
      final slice = readChatMedia(
        'c1',
        messageIndex: 0,
        mediaIndex: 0,
        length: 10,
        chatsDir: chats,
      )!;

      expect(slice.bytes, hasLength(10));
      expect(slice.size, 5000);
    });

    test('is null for a turn or an attachment that is not there, rather than '
        'reading whatever is at index zero', () {
      expect(
        readChatMedia('c1', messageIndex: 9, mediaIndex: 0, chatsDir: chats),
        isNull,
      );
      expect(
        readChatMedia('c1', messageIndex: 0, mediaIndex: 9, chatsDir: chats),
        isNull,
      );
    });

    test('is null when the file behind it has been cleared, since ~/.grid/'
        'outputs is emptied by hand and by the app', () {
      picture.deleteSync();

      expect(
        readChatMedia('c1', messageIndex: 0, mediaIndex: 0, chatsDir: chats),
        isNull,
      );
    });

    test('still refuses a chat id that is a path, the same field guarded on '
        'every other read', () {
      expect(
        readChatMedia(
          '../secret',
          messageIndex: 0,
          mediaIndex: 0,
          chatsDir: chats,
        ),
        isNull,
      );
    });

    test('keeps a turn that is only a picture, which used to vanish — a photo '
        'sent with no words was simply missing from the phone', () {
      File('${chats.path}/c2.json').writeAsStringSync(
        jsonEncode({
          'id': 'c2',
          'messages': [
            {
              'role': 'user',
              'text': '',
              'media': [
                {'path': picture.path, 'kind': 'image'},
              ],
            },
          ],
        }),
      );

      final page = readChatPage('c2', chatsDir: chats)!;

      expect(page.lines, hasLength(1));
      expect(page.lines.single.media, hasLength(1));
    });
  });

  group('what a chat says while an answer is being written', () {
    MobileRpcService hostThatIsWriting(String streaming, {bool busy = true}) =>
        MobileRpcService(
          hostName: 'test-host',
          appVersion: '0.0.0',
          readGrids: () => const [],
          readChat: (id, {int? limit, int? offset}) =>
              (lines: const <ChatLine>[], total: 4, offset: 0),
          chatIsBusy: (id) => busy,
          chatStreaming: (id) => streaming,
        );

    Future<Map<String, Object?>> head(MobileRpcService service) async {
      final answer = await service.handle(
        MobileRpcRequest(id: 'r1', method: 'chats.head', params: {'id': 'c1'}),
        deviceId: 'device-1',
      );
      return (answer as MobileRpcOk).result;
    }

    test(
      'carries the reply as far as it has been written, because a turn is '
      'not on disk until it finishes and the phone reads disk — that gap is '
      'the whole minute the phone showed a spinner and nothing else',
      () async {
        final result = await head(hostThatIsWriting('Looking at the folder'));

        expect(result['busy'], isTrue);
        expect(result['streaming'], 'Looking at the folder');
      },
    );

    test('leaves the key out entirely when nothing is being written, since '
        'this is asked about once a second and an empty key is bytes spent to '
        'say nothing', () async {
      final result = await head(hostThatIsWriting('', busy: false));

      expect(result.containsKey('streaming'), isFalse);
      expect(result['busy'], isFalse);
    });

    test('is busy with no text yet on a turn that has started but produced '
        'nothing — the phone has a spinner for that, and an empty bubble says '
        'less', () async {
      final result = await head(hostThatIsWriting(''));

      expect(result['busy'], isTrue);
      expect(result.containsKey('streaming'), isFalse);
    });

    test('answers the head of a chat without sending its forty turns, which '
        'is the reason it is a method of its own', () async {
      final result = await head(hostThatIsWriting('half an answer'));

      expect(result['total'], 4);
      expect(result.containsKey('messages'), isFalse);
    });
  });
}
