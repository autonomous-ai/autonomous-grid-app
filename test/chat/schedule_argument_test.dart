import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/schedule_argument.dart';
import 'package:grid_app/features/scheduled/logic/job_schedule.dart';

void main() {
  group('reading when a task should run', () {
    test('a named hour is the hour it runs — the one thing a user would never '
        'forgive being changed', () {
      final request = parseScheduleArgument('mỗi ngày 8h30 tóm tắt hộp thư');

      expect(request?.schedule.hour, 8);
      expect(request?.schedule.minute, 30);
      expect(request?.schedule.cadence, JobCadence.everyDay);
      expect(request?.prompt, 'tóm tắt hộp thư');
    });

    test('an evening hour lands in the evening, not before breakfast', () {
      expect(
        parseScheduleArgument('mỗi ngày 8h tối gọi mẹ')?.schedule.hour,
        20,
      );
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
      expect(parseScheduleArgument('mỗi tối dọn log')?.schedule.hour, 20);
    });

    test('"every 30 minutes" is a repeat through the day, not a daily run', () {
      final request = parseScheduleArgument('mỗi 30 phút kiểm tra deploy');

      expect(request?.schedule.cadence, JobCadence.every30Min);
      expect(request?.schedule.toSchedule(), 'every 30m');
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
        parseScheduleArgument('nhắc tôi 8h sáng gọi khách hàng')?.prompt,
        'gọi khách hàng',
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
      expect(parseScheduleArgument('mỗi sáng 8h'), isNull);
      expect(parseScheduleArgument('   '), isNull);
    });

    test('an unreadable "when" still saves the task, at an hour the user can '
        'see and change, rather than losing what they asked for', () {
      final request = parseScheduleArgument('thỉnh thoảng dọn log giúp tôi');

      expect(request?.schedule.cadence, JobCadence.everyDay);
      expect(request?.schedule.hour, 8);
      expect(request?.prompt, 'thỉnh thoảng dọn log giúp tôi');
    });
  });
}
