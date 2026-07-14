import 'job_schedule.dart';

/// A ready-made task the user can start from, so a blank Scheduled screen offers
/// something to click instead of asking them to invent a cron job.
///
/// Each one is something the assistant can genuinely do today: it reads the files
/// in the Projects folder (its working folder) and writes you back a summary. No
/// suggestion promises an inbox or a calendar the agent can't see.
class JobSuggestion {
  const JobSuggestion({
    required this.name,
    required this.prompt,
    required this.schedule,
  });

  final String name;
  final String prompt;
  final JobSchedule schedule;
}

const kJobSuggestions = [
  JobSuggestion(
    name: 'Daily digest',
    prompt:
        'Look through the files in my folder and write a short digest: what '
        'changed recently, and the two or three things worth my attention '
        'today. Keep it under ten lines.',
    schedule: JobSchedule(cadence: JobCadence.weekdays, hour: 8, minute: 0),
  ),
  JobSuggestion(
    name: 'Weekly review',
    prompt:
        'Turn the notes and documents in my folder into a short status update '
        'for the week: what got done, what is still open, what is blocked.',
    schedule: JobSchedule(
      cadence: JobCadence.weekly,
      hour: 16,
      minute: 0,
      weekday: DateTime.friday,
    ),
  ),
  JobSuggestion(
    name: 'Loose ends',
    prompt:
        'Go through my folder and list anything that looks unfinished — a draft '
        'without an ending, a TODO, a question nobody answered.',
    schedule: JobSchedule(cadence: JobCadence.weekdays, hour: 9, minute: 0),
  ),
];
