/// Presentation helpers for a grid member — pure, so the rows that draw a
/// roster stay dumb and these stay readable on their own.
///
/// A roster is a column of addresses that mostly share one domain, and the
/// repeated half is the half the eye has to skip past on every line. These cut
/// an address into the pieces a row draws differently: a letter for its circle,
/// the name in front of the `@`, and the domain behind it — printed too, but in
/// a lighter ink, so the whole address is still there to be read and copied
/// while the eye lands on the part that differs.
library;

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

/// Everything from the first `@` on — `dev@autonomous.ai` → `@autonomous.ai`
/// — or the empty string when there is no name in front of it to be the other
/// half of.
///
/// Exactly complementary to [memberLocalPart]: the two always concatenate back
/// to the trimmed address, which is what lets a roster print the whole thing
/// while drawing the half that differs in a stronger ink. An address the
/// control plane stored without an `@`, or with nothing before it, is all local
/// part and no domain — so the row prints it whole and this adds nothing,
/// rather than the two halves quietly repeating each other.
String memberDomainPart(String email) {
  final trimmed = email.trim();
  final at = trimmed.indexOf('@');
  return at <= 0 ? '' : trimmed.substring(at);
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

/// The colour slot an address hashes to, in `[0, slots)` — the same one every
/// time, on every machine, for as long as the address is the same.
///
/// The starting point only. A roster draws its circles through
/// [memberAvatarSlots], which takes this and then moves whoever landed on a
/// colour already in use — see there for why a hash alone is not enough.
///
/// A roster used to draw every circle in one fill, which made the column a
/// stack of identical marks: the letter was the only thing telling two rows
/// apart, and a letter repeats too (three people whose names start with `M`).
/// Colour is what lets a face be recognised before it is read — but only if it
/// is *stable*, so a person is the same colour in the members panel, in the top
/// bar's stack and in the share dialog, today and next week.
///
/// Hence a hash written out here rather than `String.hashCode`: the runtime is
/// free to salt that per process, and a colour that changed on restart would be
/// worse than no colour at all. FNV-1a over the address's code units — small,
/// well-spread, and pinned by tests.
///
/// Lower-cased and trimmed first: the control plane stores what the user typed,
/// so the same person can arrive as `Dev@` in one list and `dev@` in another,
/// and two colours for one person defeats the point.
int memberAvatarSlot(String email, int slots) {
  assert(slots > 0, 'a palette with no colours cannot colour anything');
  var hash = 0x811C9DC5;
  for (final unit in email.trim().toLowerCase().codeUnits) {
    hash ^= unit;
    // FNV prime, kept inside 32 bits — Dart ints are 64-bit on the VM and
    // arbitrary on the web, and a hash that overflows differently per platform
    // is not the stable thing this function promises.
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash % slots;
}

/// A colour slot per member, in the order the rows are drawn, with **no two
/// people within one screenful sharing one**.
///
/// [memberAvatarSlot] alone cannot promise that, and the numbers are not close:
/// five people drawn from eight colours come out all-different only 21% of the
/// time. Measured on this grid's own roster, the first five members hashed to
/// 5, 4, 4, 5, 5 — three violets and two ambers in the five faces the top bar
/// shows, which is the exact failure colouring a roster was meant to fix.
///
/// So the hash decides where a person *starts* and this decides where they
/// land: a slot already taken by one of the previous rows is stepped past until
/// a free one comes up. Only the last `slots - 1` assignments are held against
/// a row, which is what keeps a free slot always available — and means the
/// guarantee is "distinct within any run of [slots] rows" rather than "distinct
/// across a grid of two hundred people", which eight colours cannot honour and
/// the eye does not ask for.
///
/// Whole-list rather than per-address, because whether a mark still tells one
/// person from another is a fact about the list, not about the person. The cost
/// is that a member's colour can move when
/// somebody above them in the list does — worth it, because a column where two
/// adjacent circles match is the thing colour was added to prevent.
List<int> memberAvatarSlots(List<String> emails, int slots) {
  assert(slots > 0, 'a palette with no colours cannot colour anything');
  // What the rows just above this one took. Capped one short of the palette so
  // there is always somewhere free to land, which is what bounds the probe.
  final recent = <int>[];
  final assigned = <int>[];
  for (final email in emails) {
    var slot = memberAvatarSlot(email, slots);
    while (recent.contains(slot)) {
      slot = (slot + 1) % slots;
    }
    assigned.add(slot);
    recent.add(slot);
    if (recent.length >= slots) recent.removeAt(0);
  }
  return assigned;
}
