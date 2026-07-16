import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/scheduled/logic/job_schedule.dart';

void main() {
  group('toSchedule', () {
    test('every day', () {
      const schedule = JobSchedule(
        cadence: JobCadence.everyDay,
        hour: 9,
        minute: 30,
      );
      expect(schedule.toSchedule(), '30 9 * * *');
    });

    test('weekdays', () {
      const schedule = JobSchedule(
        cadence: JobCadence.weekdays,
        hour: 8,
        minute: 0,
      );
      expect(schedule.toSchedule(), '0 8 * * 1-5');
    });

    test('weekly on a Friday', () {
      const schedule = JobSchedule(
        cadence: JobCadence.weekly,
        hour: 16,
        minute: 0,
        weekday: DateTime.friday,
      );
      expect(schedule.toSchedule(), '0 16 * * 5');
    });

    test('a Sunday is cron day 0, not Dart day 7', () {
      const schedule = JobSchedule(
        cadence: JobCadence.weekly,
        hour: 7,
        minute: 15,
        weekday: DateTime.sunday,
      );
      expect(schedule.toSchedule(), '15 7 * * 0');
    });

    test('an interval cadence is an `every Nm`, not a cron line — and ignores '
        'the time of day', () {
      expect(
        const JobSchedule(cadence: JobCadence.every30Min).toSchedule(),
        'every 30m',
      );
      expect(
        const JobSchedule(cadence: JobCadence.hourly).toSchedule(),
        'every 60m',
      );
      expect(
        const JobSchedule(
          cadence: JobCadence.every2Hours,
          hour: 3,
        ).toSchedule(),
        'every 120m',
      );
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

    test('an interval reads as a repeat, with no time', () {
      expect(
        const JobSchedule(cadence: JobCadence.every30Min).describe(),
        'Every 30 minutes',
      );
      expect(
        const JobSchedule(cadence: JobCadence.hourly).describe(),
        'Every hour',
      );
      expect(
        const JobSchedule(cadence: JobCadence.every2Hours).describe(),
        'Every 2 hours',
      );
    });
  });

  group('parseJobSchedule', () {
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
        JobSchedule(cadence: JobCadence.every30Min),
        JobSchedule(cadence: JobCadence.hourly),
        JobSchedule(cadence: JobCadence.every2Hours),
      ];
      for (final schedule in schedules) {
        final parsed = parseJobSchedule(schedule.toSchedule());
        expect(parsed, isNotNull, reason: schedule.toSchedule());
        expect(parsed!.describe(), schedule.describe());
      }
    });

    test('reads Hermes\'s normalised interval — a 2-hour task comes back as '
        '`every 120m`', () {
      expect(parseJobSchedule('every 120m')?.cadence, JobCadence.every2Hours);
      expect(parseJobSchedule('every 60m')?.cadence, JobCadence.hourly);
      expect(parseJobSchedule('every 30m')?.cadence, JobCadence.every30Min);
    });

    test('gives up on a schedule the app did not write', () {
      // A cron the app never emits, and an interval it doesn't offer as a preset.
      expect(parseJobSchedule('*/15 * * * *'), isNull);
      expect(parseJobSchedule('every 45m'), isNull);
      expect(parseJobSchedule('nonsense'), isNull);
    });
  });

  group('describeJobSchedule', () {
    test('plain language for ours, the raw expression for anything else — an '
        'invented "every day" would be a lie', () {
      expect(describeJobSchedule('0 8 * * 1-5'), 'Every weekday at 08:00');
      expect(describeJobSchedule('every 120m'), 'Every 2 hours');
      expect(describeJobSchedule('*/15 * * * *'), '*/15 * * * *');
      expect(describeJobSchedule('every 45m'), 'every 45m');
    });
  });
}
