/// Null-tolerant readers for the relay's JSON, shared by every model here.
///
/// The shape belongs to the relay, not to this app: an older one leaves keys
/// out and a newer one adds them, and the CLI's own handlers use `.get()`
/// everywhere for that reason. Reading a key that isn't there — or is there as
/// the wrong type — must produce "not said", never an exception in a widget.
///
/// **Absent is not the same as false**, and that distinction is load-bearing
/// wherever it appears: `can_promote` missing means the relay didn't answer,
/// while `false` means the branch is behind. Callers that care keep the null.
library;

/// The value at [key] when it is a non-empty string, else null.
///
/// Empty is folded into null on purpose: every consumer here would otherwise
/// have to write `?.isEmpty` beside `!= null`, and an empty commit oid or
/// branch name is exactly as unusable as a missing one.
String? wireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The value at [key] when it is a whole number, else null.
int? wireInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is double && value == value.roundToDouble()) return value.toInt();
  return null;
}

/// The value at [key] when it is a boolean, else null — never coerced.
bool? wireBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is bool ? value : null;
}

/// The object at [key], or an empty map when it is missing or not one.
Map<String, dynamic> wireMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is Map ? Map<String, dynamic>.from(value) : const {};
}

/// The objects in the list at [key], skipping entries that aren't objects.
List<Map<String, dynamic>> wireObjects(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) return const [];
  return [
    for (final entry in value)
      if (entry is Map) Map<String, dynamic>.from(entry),
  ];
}

/// The non-empty strings in the list at [key].
///
/// Used for conflict file lists, which the relay sends as data precisely so a
/// screen doesn't have to dig them out of a sentence.
List<String> wireStrings(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) return const [];
  return [
    for (final entry in value)
      if (entry is String && entry.trim().isNotEmpty) entry.trim(),
  ];
}

/// An ISO-8601 stamp at [key], parsed, or null when it is missing or unusable.
///
/// The relay writes UTC; a stamp that won't parse is dropped rather than shown
/// raw, because a timestamp nobody can read is worse than no timestamp at all.
DateTime? wireTime(Map<String, dynamic> json, String key) {
  final raw = wireString(json, key);
  if (raw == null) return null;
  return DateTime.tryParse(raw)?.toLocal();
}
