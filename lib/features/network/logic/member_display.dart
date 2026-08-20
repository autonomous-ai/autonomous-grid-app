/// Presentation helpers for a grid member — pure, so the rows that draw a
/// roster stay dumb and these stay readable on their own.
///
/// A roster is a column of addresses that mostly share one domain, and the
/// repeated half is the half the eye has to skip past on every line. These turn
/// an address into the two things a row actually shows: a letter for its circle,
/// and the name in front of the `@`.
library;

/// Each address as the handle a roster shows — `dev@autonomous.ai` → `@dev` —
/// so a column of members reads as people rather than as the same domain printed
/// twelve times.
///
/// **The `@` moves to the front rather than being dropped.** A bare `dev` reads
/// as a word; `@dev` reads as a person, and it keeps the row honest about what
/// was cut — a name with no marker would look like the whole of what the roster
/// stores.
///
/// **Only where the short form still names one person.** Two members can share
/// a local part across domains — `abc@gmail.com` beside `abc@autonomous.ai` —
/// and shortening both would put two identical rows in a list whose whole job is
/// saying who is on the grid. A clashing address is printed in full, `@`-less
/// and unmistakable; the ones around it still become handles, the way
/// `shortenNodeNames` trims per group rather than all-or-nothing.
///
/// Compared case-insensitively: the control plane stores what the user typed, so
/// the same person can arrive as `Dev@` here and `dev@` there, and a clash that
/// differs only in case is still a clash to a reader.
List<String> memberHandles(List<String> emails) {
  final counts = <String, int>{};
  for (final email in emails) {
    final key = memberLocalPart(email).toLowerCase();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return [
    for (final email in emails)
      if (memberLocalPart(email) case final local
          when local.isNotEmpty &&
              local != email.trim() &&
              (counts[local.toLowerCase()] ?? 0) == 1)
        '@$local'
      else
        email.trim(),
  ];
}

/// The letter for a member's circle: the first character of the name in front
/// of the `@`, upper-cased.
///
/// Not upper-cased anywhere else — the row prints the address as it was stored,
/// because that is what a person copies and searches for. The circle is a mark
/// rather than a quotation, and a lower-case one reads as a typo.
///
/// The first character that is actually a character: an address stored as
/// `@example.com` has no name in front of the `@`, and a circle holding a
/// punctuation mark reads as a bug rather than as a person.
///
/// `?` when there is nothing to take at all. An address the roster somehow
/// stored empty still gets a row, and a blank circle reads as a rendering
/// failure.
String memberInitial(String email) {
  for (final char in memberLocalPart(email).split('')) {
    if (char == '@' || char.trim().isEmpty) continue;
    return char.toUpperCase();
  }
  return '?';
}

/// Everything in front of the first `@`, trimmed — or the whole string when
/// there is no `@`, or nothing in front of it.
///
/// Deliberately forgiving: the roster holds whatever the control plane accepted,
/// and a row must still name an address this never expected rather than
/// collapsing to an empty line.
String memberLocalPart(String email) {
  final trimmed = email.trim();
  final at = trimmed.indexOf('@');
  return at <= 0 ? trimmed : trimmed.substring(0, at);
}
