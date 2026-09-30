import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/phone/logic/phone_turn_controls.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/pairing_host/mobile_chat_reader.dart';
import 'package:grid_app/infrastructure/pairing_host/mobile_rpc_service.dart';
import 'package:grid_pairing/grid_pairing.dart';

import 'mobile_turn_fakes.dart';

/// What a phone is told about an agent turn in flight, and the two things it
/// may do to one — stop it, or answer the question it stopped to ask.
///
/// A wire format two separately shipped binaries decode (§8), and a gate: a
/// yes over `chats.answer` lets the agent act on this computer.
void main() {
  MobileRpcService host(FakeTurns turns) => MobileRpcService(
    hostName: 'test-host',
    appVersion: '0.0.0',
    readGrids: () => const [],
    readChat: (id, {int? limit, int? offset}) =>
        (lines: const <ChatLine>[], total: 3, offset: 0),
    turns: turns,
  );

  Future<MobileRpcResponse> ask(
    MobileRpcService service,
    String method,
    Map<String, Object?> params, {
    bool allowed = true,
  }) => service.handle(
    MobileRpcRequest(id: 'r1', method: method, params: params),
    mayAct: () async => allowed,
  );

  Map<String, Object?> ok(MobileRpcResponse answer) =>
      (answer as MobileRpcOk).result;

  const question = MobilePermission(
    id: 'q7',
    kind: MobilePermissionKind.command,
    summary: 'Delete the build folder',
    detail: 'rm -rf build',
    canAllowForChat: true,
  );

  group('the head of a chat an agent is working in', () {
    test('carries only the newest steps and the count of all of them, since '
        'it is asked every 700ms and one turn here ran 1,689 steps', () async {
      final turns = FakeTurns(
        ran: [for (var n = 1; n <= kMobileLiveSteps + 5; n++) fakeStep(n)],
      );

      final live = MobileLiveTurn.fromJson(
        ok(await ask(host(turns), 'chats.head', {'id': 'c1'})),
      )!;

      expect(live.steps, hasLength(kMobileLiveSteps));
      expect(live.steps.last.id, 's${kMobileLiveSteps + 5}');
      expect(live.stepCount, kMobileLiveSteps + 5);
    });

    test('carries the question the agent is waiting on, so the phone can '
        'answer it instead of the turn ending in a no nobody chose', () async {
      final live = MobileLiveTurn.fromJson(
        ok(
          await ask(host(FakeTurns(asking: question)), 'chats.head', {
            'id': 'c1',
          }),
        ),
      )!;

      expect(live.permission?.id, 'q7');
      expect(live.permission?.detail, 'rm -rf build');
    });

    test('says nothing about steps or questions once the turn is over, so a '
        'finished chat does not show a stale card', () async {
      final turns = FakeTurns(
        busy: false,
        ran: [fakeStep(1)],
        asking: question,
      );

      final result = ok(await ask(host(turns), 'chats.head', {'id': 'c1'}));

      expect(result['busy'], isFalse);
      expect(result.containsKey('steps'), isFalse);
      expect(result.containsKey('permission'), isFalse);
    });
  });

  group('stopping an answer from the phone', () {
    test('stops it when the phone may act', () async {
      final turns = FakeTurns();

      final result = ok(await ask(host(turns), 'chats.stop', {'id': 'c1'}));

      expect(result['stopped'], isTrue);
      expect(turns.stopped, ['c1']);
    });

    test('is refused behind the same switch as sending, because it ends work '
        'somebody may have started at the computer', () async {
      final turns = FakeTurns();

      final answer = await ask(host(turns), 'chats.stop', {
        'id': 'c1',
      }, allowed: false);

      expect((answer as MobileRpcFailed).code, 'forbidden');
      expect(turns.stopped, isEmpty);
    });

    test('says nothing was running rather than failing, when the answer '
        'finished between the tap and the call', () async {
      final result = ok(
        await ask(host(FakeTurns(busy: false)), 'chats.stop', {'id': 'c1'}),
      );

      expect(result['stopped'], isFalse);
    });
  });

  group('answering the question an agent stopped to ask', () {
    Future<MobileRpcResponse> answerWith(
      FakeTurns turns, {
      String question = 'q7',
      Object? choice = 'allowOnce',
      bool allowed = true,
    }) => ask(host(turns), 'chats.answer', {
      'id': 'c1',
      'question': question,
      'choice': choice,
    }, allowed: allowed);

    test('delivers the choice when the phone may act', () async {
      final turns = FakeTurns(asking: question);

      await answerWith(turns);

      expect(turns.answered, ['c1/q7=allowOnce']);
    });

    test('is refused without the switch, because a yes here lets the agent '
        'act on this computer', () async {
      final turns = FakeTurns(asking: question);

      final answer = await answerWith(turns, allowed: false);

      expect((answer as MobileRpcFailed).code, 'forbidden');
      expect(turns.answered, isEmpty);
    });

    test('does not answer a question that has since been replaced, so a tap '
        'on a stale card is not a yes to the next one', () async {
      final turns = FakeTurns(asking: question);

      final answer = await answerWith(turns, question: 'q6');

      expect(answer, isA<MobileRpcFailed>());
      expect(turns.answered, isEmpty);
    });

    test(
      'reads a choice it does not know as a bad request, never as a yes',
      () async {
        final turns = FakeTurns(asking: question);

        final answer = await answerWith(turns, choice: 'allowAlways');

        expect((answer as MobileRpcFailed).code, 'bad_request');
        expect(turns.answered, isEmpty);
      },
    );
  });

  test('the status says which methods this computer answers, so a phone '
      'offers Stop only where it works', () async {
    final result = ok(await ask(host(FakeTurns()), 'status.get', const {}));

    expect(result['methods'], containsAll(['chats.stop', 'chats.answer']));
  });

  group('a finished turn on a transcript page', () {
    late Directory chats;

    setUp(() {
      chats = Directory.systemTemp.createTempSync('grid-phone-steps');
    });

    tearDown(() => chats.deleteSync(recursive: true));

    test('carries the steps the agent ran, by label and outcome, and never '
        'what they read or returned', () {
      File('${chats.path}/c1.json').writeAsStringSync(
        jsonEncode({
          'id': 'c1',
          'messages': [
            {
              'role': 'assistant',
              'text': 'Done.',
              'parts': [
                {
                  'kind': 'step',
                  'id': 's1',
                  'tool': 'command',
                  'name': 'Bash',
                  'label': 'ls',
                  'status': 'done',
                  'request': 'ls -la ~',
                  'result': 'secret.txt',
                },
                {'kind': 'text', 'text': 'Done.'},
              ],
            },
          ],
        }),
      );

      final line = readChatPage('c1', chatsDir: chats)!.lines.single;
      final wire = jsonEncode(line.steps.single.toJson());

      expect(line.steps.single.label, 'ls');
      expect(line.steps.single.tool, 'Bash');
      expect(line.stepCount, 1);
      expect(wire, isNot(contains('secret.txt')));
      expect(wire, isNot(contains('ls -la')));
    });
  });

  group('the app side of the projection', () {
    test('an edit question shows the file and what it would become, not '
        'what it holds now', () {
      final wire = mobilePermissionOf(
        const AgentPermission(
          id: 42,
          kind: AgentPermissionKind.edit,
          summary: 'Edit notes.md',
          path: '/tmp/notes.md',
          oldText: 'old contents',
          newText: 'new contents',
          options: [],
        ),
      );

      expect(wire.id, '42');
      expect(wire.detail, '/tmp/notes.md');
      expect(wire.preview, 'new contents');
      expect(jsonEncode(wire.toJson()), isNot(contains('old contents')));
    });

    test('a thinking step is cut to a row, since its label is the whole '
        'reasoning', () {
      final wire = mobileStepOf(
        AgentActivity(
          id: 't1',
          kind: AgentActivityKind.thinking,
          label: 'x' * 5000,
          status: AgentActivityStatus.running,
        ),
      ).toJson();

      expect((wire['label']! as String).length, kMobileStepLabelLimit);
    });
  });

  test('a step from a newer desktop with a kind this phone does not know '
      'still draws, as a plain tool row', () {
    final step = MobileStep.fromJson({
      'id': 's1',
      'kind': 'teleport',
      'label': 'x',
      'status': 'queued',
    })!;

    expect(step.kind, MobileStepKind.tool);
    expect(step.status, MobileStepStatus.unknown);
  });
}
