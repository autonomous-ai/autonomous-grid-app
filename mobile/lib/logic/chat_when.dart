/// When a conversation was last touched, in words.
library;

/// [iso] as something short enough for a list row, relative to [now].
///
/// The computer sends `updatedAt` as an ISO-8601 UTC string because that is
/// what it has on disk; turning it into "2h ago" is the phone's job, and it is
/// done here rather than in a widget so it can be tested without one (§8).
///
/// An unparseable or missing timestamp comes back empty rather than as "now" or
/// as the epoch: a row that admits it does not know beats one that lies about
/// it, and the caller simply leaves the line off.
String chatWhen(String iso, {DateTime? now}) {
  final at = DateTime.tryParse(iso);
  if (at == null) return '';
  final moment = now ?? DateTime.now();
  final gap = moment.difference(at.toLocal());
  if (gap.isNegative || gap.inMinutes < 1) return 'just now';
  if (gap.inMinutes < 60) return '${gap.inMinutes}m ago';
  if (gap.inHours < 24) return '${gap.inHours}h ago';
  if (gap.inDays == 1) return 'yesterday';
  if (gap.inDays < 7) return '${gap.inDays}d ago';
  return '${at.toLocal().day} ${_months[at.toLocal().month - 1]}';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
