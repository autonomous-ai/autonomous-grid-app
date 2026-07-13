import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_name.dart';

void main() {
  test('accepts an ordinary grid name', () {
    expect(gridNameError('Duc AI Grid'), isNull);
  });

  test('accepts dots, dashes and underscores', () {
    expect(gridNameError('team-1_lab.v2'), isNull);
  });

  test('rejects an empty or blank name', () {
    expect(gridNameError('   '), isNotNull);
  });

  test('rejects a name that does not start with a letter or number', () {
    expect(gridNameError('-lab'), isNotNull);
    expect(gridNameError(' lab'), isNull, reason: 'leading space is trimmed');
  });

  test('rejects characters the control plane would refuse on create', () {
    expect(gridNameError('lab/prod'), isNotNull);
    expect(gridNameError('lab@home'), isNotNull);
  });

  test('rejects a name longer than the control-plane limit', () {
    expect(gridNameError('a' * gridNameMaxLength), isNull);
    expect(gridNameError('a' * (gridNameMaxLength + 1)), isNotNull);
  });

  test('rejects a name another grid already uses, ignoring case', () {
    final error = gridNameError('My Grid', takenNames: const ['my grid']);

    expect(error, contains('already have a grid'));
  });

  test('allows a name that is only taken by no one else', () {
    expect(gridNameError('My Grid', takenNames: const ['Other']), isNull);
  });
}
