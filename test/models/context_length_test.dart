import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/context_length.dart';

void main() {
  group('defaultContextLength', () {
    test('defaults to 200k when the model supports at least that', () {
      expect(defaultContextLength(262144), 200 * 1024); // 204800 → "200k"
      expect(formatContextLength(defaultContextLength(262144)), '200k');
    });

    test('falls back to the model max when it supports less than 200k', () {
      expect(defaultContextLength(131072), 131072);
      expect(defaultContextLength(65536), 65536);
    });
  });

  group('snapContextLength', () {
    test('snaps a raw value to the nearest 1k', () {
      expect(snapContextLength(205200, 262144), 200 * 1024); // 200.39k → 200k
      expect(snapContextLength(205400, 262144), 201 * 1024); // 200.59k → 201k
    });

    test('reaches values between the old power-of-two stops (e.g. 200k)', () {
      // The whole point: 200k sits between 128k and 256k and must be selectable.
      final snapped = snapContextLength(204800, 262144);
      expect(formatContextLength(snapped), '200k');
    });

    test('clamps within the floor and the model max', () {
      expect(snapContextLength(1000, 262144), minContextTokens); // below floor
      expect(snapContextLength(999999, 262144), 262144); // above max
    });
  });

  group('formatContextLength', () {
    test('formats to the nearest k', () {
      expect(formatContextLength(4096), '4k');
      expect(formatContextLength(204800), '200k');
      expect(formatContextLength(262144), '256k');
      expect(formatContextLength(40960), '40k');
    });

    test('a megabyte-scale window switches unit instead of reading 1024k', () {
      // The external-engine slider reaches 1M, and "1024k" is a number people
      // have to convert in their heads to compare against the "1M" their own
      // engine's flags are written in.
      expect(formatContextLength(1024 * 1024), '1M');
      expect(formatContextLength(2 * 1024 * 1024), '2M');
    });

    test('the decimal appears only where it says something', () {
      // 1.5M is worth reading; "1.0M" is a longer way to write 1M.
      expect(formatContextLength(1536 * 1024), '1.5M');
      expect(formatContextLength(1024 * 1024).contains('.'), isFalse);
    });

    test('just under a megabyte still reads in k', () {
      expect(formatContextLength(1023 * 1024), '1023k');
    });
  });
}
