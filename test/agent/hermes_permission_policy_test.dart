import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/hermes_permission_policy.dart';

/// The options Hermes actually offers for a dangerous command (from
/// acp_adapter/permissions.py): allow variants plus an explicit deny.
const _commandOptions = <HermesPermissionOption>[
  (optionId: 'allow_once', kind: 'allow_once'),
  (optionId: 'allow_session', kind: 'allow_always'),
  (optionId: 'allow_always', kind: 'allow_always'),
  (optionId: 'deny', kind: 'reject_once'),
  (optionId: 'deny_always', kind: 'reject_always'),
];

/// The options Hermes offers for a file edit (from edit_approval.py) — no
/// "always" of any kind.
const _editOptions = <HermesPermissionOption>[
  (optionId: 'allow_once', kind: 'allow_once'),
  (optionId: 'deny', kind: 'reject_once'),
];

Map<String, Object?> _commandRequest({
  String command = 'rm -rf build',
  String description = 'Delete the build folder',
}) => {
  'sessionId': 's1',
  'toolCall': {
    'toolCallId': 'perm-check-1',
    'title': '$description: $command',
    'kind': 'execute',
    'rawInput': {'command': command, 'description': description},
  },
  'options': [
    for (final o in _commandOptions) {'optionId': o.optionId, 'kind': o.kind},
  ],
};

Map<String, Object?> _editRequest({String? oldText = 'a\nb\n'}) => {
  'sessionId': 's1',
  'toolCall': {
    'toolCallId': 'edit-approval-1',
    'title': 'Approve edit: /work/notes.md',
    'kind': 'edit',
    'content': [
      {
        'type': 'diff',
        'path': '/work/notes.md',
        'oldText': oldText,
        'newText': 'a\nc\n',
      },
    ],
  },
  'options': [
    for (final o in _editOptions) {'optionId': o.optionId, 'kind': o.kind},
  ],
};

void main() {
  group('by default the user decides what touches their computer', () {
    test('running a command is put to the user, not decided for them', () {
      final decision = decideHermesPermission(
        toolKind: 'execute',
        options: _commandOptions,
      );
      expect(decision, isA<HermesAskUser>());
    });

    test('changing a file is put to the user', () {
      expect(
        decideHermesPermission(toolKind: 'edit', options: _editOptions),
        isA<HermesAskUser>(),
      );
    });
  });

  group('the mode the user picked in the composer decides who is asked', () {
    test('read only: it never runs anything and never changes a file', () {
      for (final kind in ['execute', 'edit']) {
        final decision = decideHermesPermission(
          toolKind: kind,
          options: _commandOptions,
          mode: AgentApprovalMode.readOnly,
        );
        expect((decision as HermesRefuse).optionId, 'deny');
      }
    });

    test('plan mode refuses actions like read-only — a planning turn touches '
        'nothing even if the mode leaks through', () {
      for (final kind in ['execute', 'edit']) {
        final decision = decideHermesPermission(
          toolKind: kind,
          options: _commandOptions,
          mode: AgentApprovalMode.plan,
        );
        expect((decision as HermesRefuse).optionId, 'deny');
      }
    });

    test('full access: no interruption — but the yes is still a one-off, never '
        'the "always" Hermes would remember after the mode is switched '
        'back', () {
      final decision = decideHermesPermission(
        toolKind: 'execute',
        options: _commandOptions,
        mode: AgentApprovalMode.full,
      );
      expect((decision as HermesAllow).optionId, 'allow_once');
    });

    test('reading is allowed in every mode — it interrupts nobody', () {
      for (final mode in AgentApprovalMode.values) {
        expect(
          decideHermesPermission(
            toolKind: 'read',
            options: _commandOptions,
            mode: mode,
          ),
          isA<HermesAllow>(),
        );
      }
    });

    test('a kind we cannot explain still follows the mode — on full access it '
        'is allowed, like every other acting tool', () {
      final decision = decideHermesPermission(
        toolKind: 'other',
        options: _commandOptions,
        mode: AgentApprovalMode.full,
      );
      expect((decision as HermesAllow).optionId, 'allow_once');
    });
  });

  group('a kind the app has never seen', () {
    test('is put to the user rather than refused behind their back — the '
        'composer says it will ask, so it asks', () {
      for (final kind in ['delete', 'move', 'other']) {
        expect(
          decideHermesPermission(toolKind: kind, options: _commandOptions),
          isA<HermesAskUser>(),
          reason: '$kind should reach the user',
        );
      }
    });

    test('is still refused in read-only, where nothing may act at all', () {
      final decision = decideHermesPermission(
        toolKind: 'delete',
        options: _commandOptions,
        mode: AgentApprovalMode.readOnly,
      );
      expect((decision as HermesRefuse).optionId, 'deny');
    });

    test('no reject option offered → cancel outright, never approve', () {
      final decision = decideHermesPermission(
        toolKind: 'other',
        options: const [(optionId: 'allow_once', kind: 'allow_once')],
        mode: AgentApprovalMode.readOnly,
      );
      expect((decision as HermesRefuse).optionId, isNull);
    });
  });

  group('safe actions never interrupt the user', () {
    test('reading, searching, fetching and thinking are allowed outright', () {
      for (final kind in safeToolKinds) {
        final decision = decideHermesPermission(
          toolKind: kind,
          options: _commandOptions,
        );
        expect((decision as HermesAllow).optionId, 'allow_once');
      }
    });

    test('prefers a one-time allow over an always-allow', () {
      final decision = decideHermesPermission(
        toolKind: 'read',
        options: const [
          (optionId: 'allow_always', kind: 'allow_always'),
          (optionId: 'allow_once', kind: 'allow_once'),
        ],
      );
      expect((decision as HermesAllow).optionId, 'allow_once');
    });

    test('a safe action with no way to say yes is refused, not approved', () {
      final decision = decideHermesPermission(
        toolKind: 'read',
        options: const [(optionId: 'deny', kind: 'reject_once')],
      );
      expect(decision, isA<HermesRefuse>());
    });
  });

  group('the user’s answer maps to the agent’s options', () {
    test('allow once is exactly once', () {
      expect(
        optionIdForChoice(AgentPermissionChoice.allowOnce, _commandOptions),
        'allow_once',
      );
    });

    test(
      '"allow in this chat" is the session grant, never the forever one',
      () {
        expect(
          optionIdForChoice(
            AgentPermissionChoice.allowForChat,
            _commandOptions,
          ),
          'allow_session',
          reason:
              'allow_always persists in Hermes config with no way to undo it '
              'from this app, so it is never handed out',
        );
      },
    );

    test('a file edit has no "in this chat" grant to give', () {
      expect(
        optionIdForChoice(AgentPermissionChoice.allowForChat, _editOptions),
        isNull,
      );
    });

    test('no is no', () {
      expect(
        optionIdForChoice(AgentPermissionChoice.refuse, _commandOptions),
        'deny',
      );
      expect(
        optionIdForChoice(AgentPermissionChoice.refuse, const []),
        isNull,
        reason: 'cancelling the request also denies it',
      );
    });
  });

  group('parsing what the agent asked for', () {
    test('a command request carries the exact command and its reason', () {
      final request = parseAgentPermission(id: 7, params: _commandRequest())!;

      expect(request.id, 7);
      expect(request.kind, AgentPermissionKind.command);
      expect(request.command, 'rm -rf build');
      expect(request.summary, 'Delete the build folder');
      expect(request.canAllowForChat, isTrue);
    });

    test('an edit request carries the file and both versions of it', () {
      final request = parseAgentPermission(id: 8, params: _editRequest())!;

      expect(request.kind, AgentPermissionKind.edit);
      expect(request.path, '/work/notes.md');
      expect(request.oldText, 'a\nb\n');
      expect(request.newText, 'a\nc\n');
      expect(request.summary, 'Change this file');
      expect(
        request.canAllowForChat,
        isFalse,
        reason: 'Hermes offers no session grant for edits',
      );
    });

    test('a file that does not exist yet is a create, not a change', () {
      final request = parseAgentPermission(
        id: 9,
        params: _editRequest(oldText: null),
      )!;
      expect(request.oldText, isNull);
      expect(request.summary, 'Create this file');
    });

    test('a shape we cannot draw is still shown, as the title over the raw '
        'request — the user reads what was actually asked', () {
      // A command with no command line, and an edit with no diff: known kinds
      // arriving without the field we draw them from. Dropping these was how a
      // request the app half-understood became a silent no.
      final noCommand = parseAgentPermission(
        id: 1,
        params: {
          'toolCall': {
            'kind': 'execute',
            'title': 'Run the nightly build',
            'rawInput': <String, Object?>{},
          },
        },
      )!;
      expect(noCommand.kind, AgentPermissionKind.other);
      expect(noCommand.summary, 'Run the nightly build');

      final noDiff = parseAgentPermission(
        id: 2,
        params: {
          'toolCall': {'kind': 'edit', 'content': const []},
        },
      )!;
      expect(noDiff.kind, AgentPermissionKind.other);
      // No title either, so it falls back to the kind rather than heading the
      // card with an empty string.
      expect(noDiff.summary, 'edit');
    });

    test('a tool the app has never heard of carries its own words and what it '
        'was passed', () {
      final request = parseAgentPermission(
        id: 7,
        params: {
          'toolCall': {
            'kind': 'delete',
            'title': 'Remove 3 files',
            'rawInput': {'paths': 'a.txt'},
          },
          'options': const [
            {'optionId': 'allow_once', 'kind': 'allow_once'},
          ],
        },
      )!;
      expect(request.kind, AgentPermissionKind.other);
      expect(request.summary, 'Remove 3 files');
      expect(request.command, contains('a.txt'));
    });

    test('a message with no tool call at all is the one thing left to refuse — '
        'there is nothing to ask about', () {
      expect(parseAgentPermission(id: 3, params: null), isNull);
      expect(parseAgentPermission(id: 4, params: const {}), isNull);
    });
  });
}
