import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/scheduled/logic/job_schedule.dart';

void main() {
  group('toCron', () {
    test('every day', () {
      const schedule = JobSchedule(
        cadence: JobCadence.everyDay,
        hour: 9,
        minute: 30,
      );
      expect(schedule.toCron(), '30 9 * * *');
    });

    test('weekdays', () {
      const schedule = JobSchedule(
        cadence: JobCadence.weekdays,
        hour: 8,
        minute: 0,
      );
      expect(schedule.toCron(), '0 8 * * 1-5');
    });

    test('weekly on a Friday', () {
      const schedule = JobSchedule(
        cadence: JobCadence.weekly,
        hour: 16,
        minute: 0,
        weekday: DateTime.friday,
      );
      expect(schedule.toCron(), '0 16 * * 5');
    });

    test('a Sunday is cron day 0, not Dart day 7', () {
      const schedule = JobSchedule(
        cadence: JobCadence.weekly,
        hour: 7,
        minute: 15,
        weekday: DateTime.sunday,
      );
      expect(schedule.toCron(), '15 7 * * 0');
    });
  });

  group('describe', () {
    test('says it the way the user set it', () {
      expect(
        const JobSchedule(
          cadence: JobCadence.weekdays,
          hour: 8,
          minute: 5,
        ).describe(),
        'Every weekday at 08:05',
      );
      expect(
        const JobSchedule(
          cadence: JobCadence.weekly,
          hour: 16,
          minute: 0,
          weekday: DateTime.friday,
        ).describe(),
        'Every Friday at 16:00',
      );
    });
  });

  group('parseJobCron', () {
    test('round-trips every cadence the app can write', () {
      const schedules = [
        JobSchedule(cadence: JobCadence.everyDay, hour: 9, minute: 0),
        JobSchedule(cadence: JobCadence.weekdays, hour: 8, minute: 30),
        JobSchedule(
          cadence: JobCadence.weekly,
          hour: 16,
          minute: 0,
          weekday: DateTime.sunday,
        ),
      ];
      for (final schedule in schedules) {
        final parsed = parseJobCron(schedule.toCron());
        expect(parsed, isNotNull, reason: schedule.toCron());
        expect(parsed!.describe(), schedule.describe());
      }
    });

    test('gives up on an expression the app did not write', () {
      // Written by hand in Hermes: every 15 minutes.
      expect(parseJobCron('*/15 * * * *'), isNull);
      expect(parseJobCron('nonsense'), isNull);
    });
  });

  group('describeJobCron', () {
    test('plain language for ours, the raw expression for anything else — an '
        'invented "every day" would be a lie', () {
      expect(describeJobCron('0 8 * * 1-5'), 'Every weekday at 08:00');
      expect(describeJobCron('*/15 * * * *'), '*/15 * * * *');
    });
  });
}
