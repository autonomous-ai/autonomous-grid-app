import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

void main() {
  group('how long an answer took, as the transcript says it', () {
    test('a turn that failed before it began keeps its milliseconds — rounding '
        'it to "0.0s" would hide the one number that says nothing ran', () {
      expect(formatTurnDuration(const Duration(milliseconds: 2)), '2ms');
      expect(formatTurnDuration(const Duration(milliseconds: 840)), '840ms');
    });

    test('a few seconds keeps a tenth, because the difference between 2.1s and '
        '2.9s is the difference between two models', () {
      expect(formatTurnDuration(const Duration(milliseconds: 1000)), '1.0s');
      expect(formatTurnDuration(const Duration(milliseconds: 8449)), '8.4s');
    });

    test('past ten seconds the tenth stops meaning anything and goes', () {
      expect(formatTurnDuration(const Duration(milliseconds: 10400)), '10s');
      expect(formatTurnDuration(const Duration(seconds: 42)), '42s');
    });

    test('a long agent turn reads as minutes and seconds, zero-padded so a '
        'column of them lines up', () {
      expect(formatTurnDuration(const Duration(seconds: 60)), '1m 00s');
      expect(
        formatTurnDuration(const Duration(minutes: 3, seconds: 5)),
        '3m 05s',
      );
      expect(
        formatTurnDuration(const Duration(minutes: 10, seconds: 18)),
        '10m 18s',
      );
    });

    test('an hour-long turn stops counting seconds — nobody reads them at that '
        'scale', () {
      expect(
        formatTurnDuration(const Duration(hours: 1, minutes: 4, seconds: 30)),
        '1h 04m',
      );
    });

    test('a zero or nonsense duration says so instead of throwing — the value '
        'can come off disk, where anything is possible', () {
      expect(formatTurnDuration(Duration.zero), '0ms');
      expect(formatTurnDuration(const Duration(milliseconds: -5)), '0ms');
    });
  });
}
