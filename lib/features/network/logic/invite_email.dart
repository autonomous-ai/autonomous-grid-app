/// Client-side checks on an address typed into the invite field.
///
/// Not RFC 5322 — that grammar allows quoted strings, comments and bracketed IP
/// literals that no one types into an invite box, and implementing it would
/// *accept* more junk than it rejects. These are the rules a person actually
/// breaks: a missing or doubled `@`, a typo'd domain, a stray space pasted in
/// from a chat message.
///
/// **The server is still the validator.** This only saves an obvious round trip
/// and, more to the point, says *what* is wrong — a 422 comes back as one flat
/// "Invalid email", while a message naming the half that's broken is something
/// the user can act on.
library;

/// The longest an address may be, and its parts. From SMTP's own limits: 254
/// total (RFC 5321 §4.5.3.1 path limit), 64 before the `@`, 63 per dot-label
/// after it.
const _maxTotal = 254;
const _maxLocal = 64;
const _maxLabel = 63;

/// Characters allowed before the `@`. The RFC's "atext" set — letters, digits
/// and a fistful of punctuation — plus the dot, whose placement is checked
/// separately because the set alone would allow `.a..b.`.
final _localChars = RegExp(r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$");

/// One dot-separated label of the domain: alphanumeric at both ends, hyphens
/// allowed only inside. This is what rejects `-example.com` and `example-.com`.
final _label = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$');

/// A real TLD is letters only — `.com`, `.ai`, `.network`. Digits here mean the
/// user typed an IP or fat-fingered the ending.
final _letters = RegExp(r'^[A-Za-z]+$');

/// Why [raw] isn't a usable email address, or null when it is.
///
/// Returns a sentence rather than a bool so the field can say which half is
/// wrong. Order matters: the checks run from the mistake a person is most
/// likely to have made to the most obscure, so the first thing they read is the
/// thing they did.
String? inviteEmailError(String raw) {
  final email = raw.trim();
  if (email.isEmpty) return 'Enter an email address.';
  // Checked before splitting on `@`: a pasted address with a space in it would
  // otherwise be reported as a bad local part, which sends the user hunting in
  // the wrong half.
  if (email.contains(RegExp(r'\s'))) {
    return "An email address can't contain spaces.";
  }
  if (email.length > _maxTotal) return 'That email address is too long.';

  final at = email.indexOf('@');
  if (at < 0) {
    return 'An email address needs an @ — like teammate@example.com.';
  }
  if (email.indexOf('@', at + 1) >= 0) {
    return 'An email address can only have one @.';
  }

  final local = email.substring(0, at);
  final domain = email.substring(at + 1);
  if (local.isEmpty) return 'Add the part before the @.';
  if (domain.isEmpty) return 'Add the part after the @ — like example.com.';
  if (local.length > _maxLocal) return 'The part before the @ is too long.';
  if (!_localChars.hasMatch(local)) {
    return "The part before the @ has characters an address can't use.";
  }
  if (local.startsWith('.') || local.endsWith('.') || local.contains('..')) {
    return "The part before the @ can't start or end with a dot, or use two "
        'in a row.';
  }

  if (!domain.contains('.')) {
    return 'The part after the @ needs a dot — like example.com.';
  }
  // Said before the per-label loop, which would otherwise report a leading or
  // trailing dot as "two dots in a row" — an empty label at the edge has no
  // second dot beside it, and a message describing a mistake the user didn't
  // make sends them looking in the wrong place.
  if (domain.startsWith('.') || domain.endsWith('.')) {
    return "The part after the @ can't start or end with a dot.";
  }
  final labels = domain.split('.');
  for (final label in labels) {
    if (label.isEmpty) {
      return "The part after the @ can't have two dots in a row.";
    }
    if (label.length > _maxLabel) {
      return 'The part after the @ is too long.';
    }
    if (!_label.hasMatch(label)) {
      return "The part after the @ has characters an address can't use.";
    }
  }
  if (labels.last.length < 2 || !_letters.hasMatch(labels.last)) {
    return 'The part after the @ needs a real ending — like .com or .ai.';
  }
  return null;
}
