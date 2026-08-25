/// How long ago something happened, in the fewest characters that still
/// read as a duration: "now", "5m", "3h", "2d", "1w", "3mo", "1y".
///
/// Short because of where it sits — pinned to the right of a title in a small
/// hover card, where "3 days ago" would eat the room the title needs. The
/// coarse buckets are the point: on a sidebar preview the question is "recent
/// or old", not the minute it happened.
///
/// A timestamp in the future (a clock that stepped back, a row written by a
/// machine running ahead) reads as "now" rather than a negative age.
///
/// Lives in `core/` rather than under the feature that first needed it: chat's
/// hover card, the backup tile and the invitations menu all ask the same
/// question, and two of them were already importing it across a feature
/// boundary (§1). One copy, so three screens cannot start rounding differently.
String ageLabel(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  if (d.inDays < 30) return '${d.inDays ~/ 7}w';
  if (d.inDays < 365) return '${d.inDays ~/ 30}mo';
  return '${d.inDays ~/ 365}y';
}
