import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_permissions.dart';
import 'package:grid_app/features/agent/presentation/agent_permission_card.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/hermes_permission_policy.dart';

const _commandOptions = <HermesPermissionOption>[
  (optionId: 'allow_once', kind: 'allow_once'),
  (optionId: 'allow_session', kind: 'allow_always'),
  (optionId: 'deny', kind: 'reject_once'),
];

const _command = AgentPermission(
  id: 1,
  kind: AgentPermissionKind.command,
  summary: 'Delete the build folder',
  command: 'rm -rf build',
  options: _commandOptions,
);

const _edit = AgentPermission(
  id: 2,
  kind: AgentPermissionKind.edit,
  summary: 'Change this file',
  path: '/work/notes.md',
  oldText: 'one\ntwo\n',
  newText: 'one\nTWO\n',
  options: [
    (optionId: 'allow_once', kind: 'allow_once'),
    (optionId: 'deny', kind: 'reject_once'),
  ],
);

/// Records what the agent was told, in place of a live session.
Future<List<String?>> _pump(
  WidgetTester tester,
  AgentPermission request,
) async {
  final answers = <String?>[];
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(agentPermissionProvider.notifier).ask(request, answers.add);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: AgentPermissionCard(request: request)),
      ),
    ),
  );
  return answers;
}

void main() {
  testWidgets('a command is shown exactly as it would run', (tester) async {
    final answers = await _pump(tester, _command);

    expect(find.text('Run this on your computer?'), findsOneWidget);
    expect(find.text('rm -rf build'), findsOneWidget);
    expect(find.text('Delete the build folder'), findsOneWidget);

    await tester.tap(find.text('Allow once'));
    expect(answers, ['allow_once']);
  });

  testWidgets('saying no sends no', (tester) async {
    final answers = await _pump(tester, _command);

    await tester.tap(find.text("Don't allow"));
    expect(answers, ['deny']);
  });

  testWidgets('an edit shows the file and the lines that change', (
    tester,
  ) async {
    final answers = await _pump(tester, _edit);

    expect(find.text('Change this file?'), findsOneWidget);
    expect(find.text('/work/notes.md'), findsOneWidget);
    expect(find.text('- two'), findsOneWidget);
    expect(find.text('+ TWO'), findsOneWidget);
    // Hermes offers no standing grant for edits, so the app must not pretend to.
    expect(find.text('Allow in this chat'), findsNothing);

    // Answering settles the wait — otherwise the card is still counting down.
    await tester.tap(find.text('Allow once'));
    expect(answers, ['allow_once']);
  });

  testWidgets('a standing grant is only offered when the agent offers one', (
    tester,
  ) async {
    final answers = await _pump(tester, _command);

    await tester.tap(find.text('Allow in this chat'));
    expect(answers, ['allow_session']);
  });
}
