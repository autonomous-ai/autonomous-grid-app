import 'package:flutter_test/flutter_test.dart';
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

/// The options Hermes offers for a file edit (from edit_approval.py).
const _editOptions = <HermesPermissionOption>[
  (optionId: 'allow_once', kind: 'allow_once'),
  (optionId: 'deny', kind: 'reject_once'),
];

void main() {
  group('dangerous actions are refused by default', () {
    test('running a shell command (execute) is denied', () {
      final id = decideHermesPermission(
        toolKind: 'execute',
        options: _commandOptions,
      );
      expect(id, 'deny', reason: 'a chat must not silently run commands');
    });

    test('editing a file is denied', () {
      final id = decideHermesPermission(
        toolKind: 'edit',
        options: _editOptions,
      );
      expect(id, 'deny');
    });

    test('delete and move are denied too', () {
      for (final kind in ['delete', 'move']) {
        expect(
          decideHermesPermission(toolKind: kind, options: _commandOptions),
          'deny',
          reason: '$kind writes to the machine',
        );
      }
    });

    test('an unknown kind fails closed (denied), not open', () {
      expect(
        decideHermesPermission(toolKind: 'other', options: _commandOptions),
        'deny',
      );
      // No reject option offered → cancel outright rather than approve.
      expect(
        decideHermesPermission(
          toolKind: 'other',
          options: const [(optionId: 'allow_once', kind: 'allow_once')],
        ),
        isNull,
      );
    });
  });

  group('safe actions are allowed', () {
    test('reading, searching, fetching and thinking are approved', () {
      for (final kind in safeToolKinds) {
        expect(
          decideHermesPermission(toolKind: kind, options: _commandOptions),
          'allow_once',
          reason: '$kind only reads',
        );
      }
    });

    test('prefers a one-time allow over an always-allow', () {
      final id = decideHermesPermission(
        toolKind: 'read',
        options: const [
          (optionId: 'allow_always', kind: 'allow_always'),
          (optionId: 'allow_once', kind: 'allow_once'),
        ],
      );
      expect(id, 'allow_once', reason: 'never widen scope beyond one call');
    });
  });

  test('no options at all → cancel (deny)', () {
    expect(
      decideHermesPermission(toolKind: 'execute', options: const []),
      isNull,
    );
  });
}
