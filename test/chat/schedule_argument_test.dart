import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/schedule_argument.dart';
import 'package:grid_app/features/scheduled/logic/job_schedule.dart';

void main() {
  group('reading when a task should run', () {
    test('a named hour is the hour it runs — the one thing a user would never '
        'forgive being changed', () {
      final request = parseScheduleArgument(
        'every day at 8:30 summarise the inbox',
      );

      expect(request?.schedule.hour, 8);
      expect(request?.schedule.minute, 30);
      expect(request?.schedule.cadence, JobCadence.everyDay);
      expect(request?.prompt, 'summarise the inbox');
    });

    test('an evening hour lands in the evening, not before breakfast', () {
      expect(
        parseScheduleArgument('every day at 8pm call mum')?.schedule.hour,
        20,
      );
    });

    test('a part of the day with no clock gets that part\'s hour, not '
        'midnight — which is what a bare cadence would have given', () {
      expect(
        parseScheduleArgument(
          'every morning summarise the inbox',
        )?.schedule.hour,
        8,
      );
      expect(
        parseScheduleArgument('every evening clear the logs')?.schedule.hour,
        20,
      );
    });

    test('"every 30 minutes" is a repeat through the day, not a daily run', () {
      final request = parseScheduleArgument(
        'every 30 minutes check the deploy',
      );

      expect(request?.schedule.cadence, JobCadence.every30Min);
      expect(request?.schedule.toSchedule(), 'every 30m');
    });

    test('an hourly repeat keeps its cadence rather than quietly becoming a '
        'once-a-day task', () {
      final hourly = parseScheduleArgument('every hour scan X');
      expect(hourly?.schedule.cadence, JobCadence.hourly);
      expect(hourly?.prompt, 'scan X');

      final twoHourly = parseScheduleArgument('every 2 hours check the deploy');
      expect(twoHourly?.schedule.cadence, JobCadence.every2Hours);
      expect(twoHourly?.prompt, 'check the deploy');
    });

    test('weekdays only, when that is what was asked for', () {
      expect(
        parseScheduleArgument(
          'every weekday at 9 check the queue',
        )?.schedule.cadence,
        JobCadence.weekdays,
      );
    });

    test('the task keeps the user\'s own words, with only the timing taken '
        'off the front', () {
      expect(
        parseScheduleArgument('remind me at 8 call the client')?.prompt,
        'call the client',
      );
      expect(
        parseScheduleArgument(
          'schedule every morning at 8 summarise the inbox',
        )?.prompt,
        'summarise the inbox',
      );
    });

    test('words that name a time and nothing to do save no task — a job with '
        'no prompt would fire every morning and do nothing', () {
      expect(parseScheduleArgument('every morning at 8'), isNull);
      expect(parseScheduleArgument('   '), isNull);
    });

    test('an unreadable "when" still saves the task, at an hour the user can '
        'see and change, rather than losing what they asked for', () {
      const asked = 'now and then, clear the logs for me';
      final request = parseScheduleArgument(asked);

      expect(request?.schedule.cadence, JobCadence.everyDay);
      expect(request?.schedule.hour, 8);
      expect(request?.prompt, asked);
    });
  });

  group('the readings a review caught before they shipped', () {
    test('a digit inside the task is not the hour it runs at — "the 3h build" '
        'used to fire the task at three in the morning', () {
      final request = parseScheduleArgument(
        'every day at 8 restart the 3h build',
      );

      expect(request?.schedule.hour, 8);
      expect(request?.prompt, 'restart the 3h build');
    });

    test('a bare hour after "at" is read, rather than falling back to the '
        'default while the sentence plainly named one', () {
      final request = parseScheduleArgument('every day at 9 check the queue');

      expect(request?.schedule.hour, 9);
      expect(request?.prompt, 'check the queue');
    });

    test('an interval leaves no half a unit on the front of the task', () {
      expect(
        parseScheduleArgument('every 30 minutes check the deploy')?.prompt,
        'check the deploy',
      );
      expect(
        parseScheduleArgument('every 30 minutes summarise the inbox')?.prompt,
        'summarise the inbox',
      );
    });
  });
}
