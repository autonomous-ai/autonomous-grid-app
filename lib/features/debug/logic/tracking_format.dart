import '../../../infrastructure/analytics/analytics_log.dart';

/// The params a call site passed, on one line: `screen=chat · signed_in=true`.
///
/// The row can only hold a line, and the line has to say *which* event this was
/// — `screen_view` on its own is thirty identical rows. The whole payload,
/// context and identity included, is a click away in the detail dialog.
String trackedParamsSummary(Map<String, Object?> params) =>
    params.entries.map((e) => '${e.key}=${e.value}').join(' · ');

/// The word for a status, as both the row and its pill say it.
String trackedStatusLabel(AnalyticsEventStatus status) => switch (status) {
  AnalyticsEventStatus.queued => 'Waiting',
  AnalyticsEventStatus.sent => 'Sent',
  AnalyticsEventStatus.refused => 'Refused',
  AnalyticsEventStatus.dropped => 'Dropped',
};

/// What the row says under the event name: why it failed if it did, else the
/// params it carried. The failure wins — a dropped event's params are not the
/// thing anyone opened this tab to read.
String trackedSummaryLine(AnalyticsLogEntry entry) {
  final note = entry.note;
  if (note != null && note.isNotEmpty) return note;
  return trackedParamsSummary(entry.params);
}
