import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/subscription_usage.dart';

void main() {
  group("reading an assistant's own rate limits", () {
    test('Claude names its windows, and both are mapped in the order they '
        'bite', () {
      final windows = claudeUsageWindows({
        'five_hour': {'utilization': 11, 'resets_at': '2026-09-10T14:00:00Z'},
        'seven_day': {'utilization': 40.5},
      });
      expect(windows.map((w) => w.label), ['Session', 'Weekly']);
      expect(windows.first.usedPercent, 11);
      expect(windows.first.resetsAt, DateTime.utc(2026, 9, 10, 14));
      // No reset sent is no countdown drawn, never a zero.
      expect(windows.last.resetsAt, isNull);
    });

    test('a window the server stopped sending costs its row, not the whole '
        'reading — which is what keeps a newer server readable', () {
      final windows = claudeUsageWindows({
        'seven_day': {'used_percentage': 40},
      });
      expect(windows.single.label, 'Weekly');
      expect(windows.single.usedPercent, 40);
    });

    test('Codex numbers its windows and states how long each one is, so the '
        'label is read off the payload rather than assumed', () {
      final windows = codexUsageWindows({
        'rate_limit': {
          'primary_window': {
            'used_percent': 9,
            'limit_window_seconds': 18000,
            'reset_at': 1789000000,
          },
          'secondary_window': {
            'used_percent': 62,
            'limit_window_seconds': 604800,
          },
        },
      });
      expect(windows.map((w) => w.label), ['5h', 'Weekly']);
      expect(windows.first.resetsAt, isNotNull);
    });

    test('a Codex window whose length the server did not state is named for '
        'nothing rather than guessed at — a made-up "5h" beside a real '
        'percentage would be read as measured', () {
      expect(codexWindowLabel(null), 'Limit');
      expect(codexWindowLabel(0), 'Limit');
      expect(codexWindowLabel(1800), '30m');
      expect(codexWindowLabel(86400 * 3), '3d');
    });

    test('a payload with no rate limit in it yields no windows, which the '
        'caller reports as a failed reading rather than as zero usage', () {
      expect(codexUsageWindows(const {}), isEmpty);
      expect(claudeUsageWindows(const {'five_hour': 'nonsense'}), isEmpty);
    });

    test('a reset time is read from either shape a vendor sends: seconds, '
        'milliseconds, or an ISO string', () {
      final seconds = parseResetTimestamp(1789000000);
      final millis = parseResetTimestamp(1789000000000);
      expect(seconds, millis);
      expect(
        parseResetTimestamp('2026-09-10T14:00:00Z'),
        DateTime.utc(2026, 9, 10, 14),
      );
      expect(parseResetTimestamp(null), isNull);
      expect(parseResetTimestamp('later'), isNull);
    });

    test('the countdown is dropped once it has run out, because a clock '
        'running backwards is worse than no clock', () {
      final now = DateTime.utc(2026, 9, 10, 12);
      expect(
        usageResetLabel(
          now.add(const Duration(hours: 3, minutes: 36)),
          now: now,
        ),
        '3h 36m',
      );
      expect(
        usageResetLabel(now.add(const Duration(days: 6, hours: 23)), now: now),
        '6d 23h',
      );
      expect(
        usageResetLabel(now.subtract(const Duration(minutes: 1)), now: now),
        isNull,
      );
      expect(usageResetLabel(null), isNull);
    });

    test('how fresh a reading is, at the granularity the poll actually has — '
        'a "12 seconds ago" over a four-minute-old figure is a claim about '
        'the wrong thing', () {
      final now = DateTime.utc(2026, 9, 10, 12);
      expect(usageFreshnessLabel(now, now: now), 'Updated just now');
      expect(
        usageFreshnessLabel(now.subtract(const Duration(minutes: 4)), now: now),
        'Updated 4m ago',
      );
      expect(
        usageFreshnessLabel(now.subtract(const Duration(hours: 5)), now: now),
        'Updated 5h ago',
      );
      // A clock that moved backwards reads as now, never as a negative age.
      expect(
        usageFreshnessLabel(now.add(const Duration(minutes: 5)), now: now),
        'Updated just now',
      );
    });

    test('a reading carries equality, so an unchanged poll does not repaint '
        'the rail on a timer', () {
      const reading = AgentUsageWindow(label: 'Session', usedPercent: 11);
      expect(
        reading,
        const AgentUsageWindow(label: 'Session', usedPercent: 11),
      );
      expect(
        reading == const AgentUsageWindow(label: 'Session', usedPercent: 12),
        isFalse,
      );
    });
  });
}
