/// What an assistant's own account has spent of its rate limits — the figures
/// the rail reports while a chat answers off the grid.
///
/// The vendors answer in different shapes (Claude names its windows, Codex
/// numbers them and states their length), so both are mapped onto one model
/// before anything draws them. A rail that had to know which vendor it was
/// printing would grow a branch per vendor in every widget.
///
/// ⚠️ **Both endpoints behind this are undocumented** — they are what each CLI
/// asks when it prints its own usage, and they answer only to the token that
/// CLI signed in with. They can change without notice; when they do, the
/// failure is a parse that finds no window, reported as a state rather than
/// thrown. Field names here are taken from the shapes those endpoints actually
/// return, never guessed (§7).
library;

import 'agent_catalog.dart';

/// One rate-limit window: how much of it is spent, and when it starts over.
class AgentUsageWindow {
  const AgentUsageWindow({
    required this.label,
    required this.usedPercent,
    this.resetsAt,
  });

  /// What the window is called on screen — `Session`, `Weekly`, or a duration
  /// Codex stated for itself.
  final String label;

  /// How much of the window is spent, 0–100.
  final double usedPercent;

  /// When it starts over, or null when the vendor did not say.
  ///
  /// **Null is not zero.** A window with no reset time prints no countdown;
  /// "resets in 0m" for an answer we never got is a measurement invented out of
  /// a silence.
  final DateTime? resetsAt;

  @override
  bool operator ==(Object other) =>
      other is AgentUsageWindow &&
      other.label == label &&
      other.usedPercent == usedPercent &&
      other.resetsAt == resetsAt;

  @override
  int get hashCode => Object.hash(label, usedPercent, resetsAt);
}

/// Why an account's figures are, or are not, on screen.
///
/// [signedOut] is kept apart from [failed] on purpose: signing in fixes the
/// first and retrying fixes the second, and offering a retry for a missing
/// session fails identically forever.
enum AgentUsageStatus { loading, ok, signedOut, failed }

/// One reading for one assistant.
class AgentUsage {
  const AgentUsage({
    required this.agent,
    required this.status,
    this.windows = const [],
    this.message,
    this.fetchedAt,
  });

  const AgentUsage.loading(this.agent)
    : status = AgentUsageStatus.loading,
      windows = const [],
      message = null,
      fetchedAt = null;

  final AgentTool agent;
  final AgentUsageStatus status;
  final List<AgentUsageWindow> windows;

  /// What to say instead of the figures — the sentence a person can act on.
  final String? message;

  final DateTime? fetchedAt;

  /// Carries [operator ==] because this is held as provider state and rebuilt
  /// from the wire on every poll: without one, an unchanged reading notifies as
  /// a change and the rail repaints on a timer (conventions §2).
  @override
  bool operator ==(Object other) =>
      other is AgentUsage &&
      other.agent == agent &&
      other.status == status &&
      other.message == message &&
      other.fetchedAt == fetchedAt &&
      _sameWindows(other.windows, windows);

  @override
  int get hashCode =>
      Object.hash(agent, status, message, fetchedAt, Object.hashAll(windows));
}

bool _sameWindows(List<AgentUsageWindow> a, List<AgentUsageWindow> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The windows in Claude Code's usage payload, in the order they bite.
///
/// `five_hour` and `seven_day` are the two the CLI itself prints. An absent
/// window is simply not drawn, so a build reading a newer server loses a row
/// rather than the whole reading.
List<AgentUsageWindow> claudeUsageWindows(Map<Object?, Object?> data) => [
  ?_namedWindow('Session', data['five_hour']),
  ?_namedWindow('Weekly', data['seven_day']),
];

AgentUsageWindow? _namedWindow(String label, Object? raw) {
  if (raw is! Map) return null;
  final used = parseUsedPercent([raw['utilization'], raw['used_percentage']]);
  if (used == null) return null;
  return AgentUsageWindow(
    label: label,
    usedPercent: used,
    resetsAt: parseResetTimestamp(raw['resets_at']),
  );
}

/// The windows in Codex's usage payload.
///
/// Codex numbers its windows rather than naming them and states each one's real
/// length, so the labels are derived from what it sent — see
/// [codexWindowLabel].
List<AgentUsageWindow> codexUsageWindows(Map<Object?, Object?> data) {
  final limits = data['rate_limit'];
  if (limits is! Map) return const [];
  return [
    ?_codexWindow(limits['primary_window']),
    ?_codexWindow(limits['secondary_window']),
  ];
}

AgentUsageWindow? _codexWindow(Object? raw) {
  if (raw is! Map) return null;
  final used = parseUsedPercent([raw['used_percent']]);
  if (used == null) return null;
  return AgentUsageWindow(
    label: codexWindowLabel(raw['limit_window_seconds']),
    usedPercent: used,
    resetsAt: parseResetTimestamp(raw['reset_at']),
  );
}

/// Names a Codex window by how long it actually is.
///
/// Falls back to the neutral "Limit" rather than guessing: a window whose
/// length the server did not state is one this build knows nothing about, and a
/// made-up "5h" beside a real percentage would be read as measured.
String codexWindowLabel(Object? seconds) {
  final value = seconds is num && seconds.isFinite && seconds > 0
      ? seconds.round()
      : null;
  if (value == null) return 'Limit';
  final hours = value ~/ 3600;
  if (hours < 1) return '${value ~/ 60}m';
  if (hours < 24) return '${hours}h';
  final days = hours ~/ 24;
  return days == 7 ? 'Weekly' : '${days}d';
}

/// A vendor's utilization figure, clamped to the 0–100 the rail draws.
///
/// The vendors disagree on the field name, so the caller passes each candidate
/// in turn and the first that is actually a number wins.
double? parseUsedPercent(List<Object?> candidates) {
  for (final candidate in candidates) {
    final value = candidate is num
        ? candidate.toDouble()
        : double.tryParse('$candidate');
    if (value != null && value.isFinite) return value.clamp(0, 100).toDouble();
  }
  return null;
}

/// When a window resets, from either shape the vendors send: an ISO string, or
/// an epoch in seconds or milliseconds.
DateTime? parseResetTimestamp(Object? value) {
  if (value is num) {
    if (!value.isFinite) return null;
    // Ten billion is the seconds/milliseconds watershed: any epoch in seconds
    // this side of the year 2286 is below it, and any in milliseconds is above.
    final ms = value > 10000000000 ? value : value * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms.round());
  }
  if (value is! String || value.trim().isEmpty) return null;
  final numeric = num.tryParse(value.trim());
  if (numeric != null) return parseResetTimestamp(numeric);
  return DateTime.tryParse(value);
}

/// How long until [resetsAt], as the rail says it — `3h 36m`, `6d 23h`.
///
/// Null when the vendor named no reset, and for one already past: a countdown
/// running backwards is worse than no countdown, and the next poll will carry
/// the new window.
String? usageResetLabel(DateTime? resetsAt, {DateTime? now}) {
  if (resetsAt == null) return null;
  final left = resetsAt.difference(now ?? DateTime.now());
  if (left.isNegative || left.inMinutes < 1) return null;
  final days = left.inDays;
  if (days > 0) return '${days}d ${left.inHours % 24}h';
  final hours = left.inHours;
  if (hours > 0) return '${hours}h ${left.inMinutes % 60}m';
  return '${left.inMinutes}m';
}

/// How long ago a reading was taken, at the granularity the refresh behind it
/// actually has.
///
/// Anything finer would be a precision the five-minute poll cannot support: a
/// figure that says "12 seconds ago" while the number under it is four minutes
/// old is a claim about the wrong thing.
String usageFreshnessLabel(DateTime fetchedAt, {DateTime? now}) {
  final age = (now ?? DateTime.now()).difference(fetchedAt);
  if (age.isNegative || age.inMinutes < 1) return 'Updated just now';
  if (age.inMinutes < 60) return 'Updated ${age.inMinutes}m ago';
  if (age.inHours < 24) return 'Updated ${age.inHours}h ago';
  return 'Updated ${age.inDays}d ago';
}
