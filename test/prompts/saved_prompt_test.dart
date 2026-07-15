import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/prompts/logic/saved_prompt.dart';

void main() {
  group('SavedPrompt.fromJson — tolerant of a hand-edited file', () {
    test('reads a well-formed row', () {
      final prompt = SavedPrompt.fromJson({
        'id': 'p1',
        'name': 'Weekly report',
        'body': 'Write a status update.',
      });
      expect(prompt, isNotNull);
      expect(prompt!.name, 'Weekly report');
      expect(prompt.body, 'Write a status update.');
    });

    test('drops a row missing a field instead of throwing', () {
      expect(SavedPrompt.fromJson({'id': 'p1', 'name': 'x'}), isNull);
      expect(SavedPrompt.fromJson('not a map'), isNull);
    });

    test(
      'drops a row with an empty id or blank name — it could not be used',
      () {
        expect(
          SavedPrompt.fromJson({'id': '', 'name': 'x', 'body': 'y'}),
          isNull,
        );
        expect(
          SavedPrompt.fromJson({'id': 'p', 'name': ' ', 'body': 'y'}),
          isNull,
        );
      },
    );
  });

  test('toJson/fromJson round-trips a prompt unchanged', () {
    const prompt = SavedPrompt(id: 'p1', name: 'Report', body: 'Do the thing');
    expect(SavedPrompt.fromJson(prompt.toJson()), prompt);
  });

  test('copyWith keeps the id stable so edits target the same entry', () {
    const prompt = SavedPrompt(id: 'p1', name: 'Old', body: 'x');
    final renamed = prompt.copyWith(name: 'New');
    expect(renamed.id, 'p1');
    expect(renamed.name, 'New');
    expect(renamed.body, 'x');
  });
}
