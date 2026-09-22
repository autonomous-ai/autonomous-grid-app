/// The connect code a person carries from a computer to a phone, and the two
/// values derived from it.
///
/// It is the only thing a phone is ever given. There is no pairing code
/// carrying an address, no relay to name, and no invite to race: twenty
/// characters say *which* document on the locator holds this computer's current
/// address, and *unlock* it. Where the computer actually is changes as often as
/// its tunnel does, and none of that reaches the person holding the phone.
///
/// **Two derivations, two domains.** [locatorDocId] travels in a URL — it is in
/// Google's request logs, in any proxy on the way, and in this app's own error
/// text — while [locatorKey] never leaves the two devices. Deriving both from
/// one hash would be posting the key taped to the padlock, so each gets its own
/// prefix, exactly as `me-truyen-chu` separates its own two values.
///
/// **The token is also the credential the phone presents** once the channel is
/// sealed (`E2eeAuth.deviceToken`), rather than a third derived value. That is a
/// choice worth stating: the token never travels except inside the encrypted
/// channel, and one secret with one lifetime is one thing to revoke. A phone is
/// given its own token, so revoking it leaves every other phone working.
///
/// **100 bits, and it has to be.** The locator is a public database: anyone may
/// ask Firestore for any document id. What keeps a computer's address private is
/// that nobody can guess which of 2^100 names to ask for — so the token is
/// generated with [Random.secure] and never from a counter, a timestamp, or a
/// name somebody chose.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The characters a token is written in: Crockford base32.
///
/// `I`, `L`, `O` and `U` are absent. The first three because a token gets read
/// aloud and copied by hand, and `1`/`I`/`l` and `0`/`O` are the two mistakes
/// that always get made; `U` because Crockford drops it and there is no reason
/// to differ from the alphabet people can look up.
const String kPairTokenAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Characters in a token. 20 × 5 bits = 100 bits.
const int kPairTokenLength = 20;

/// The most text [PairToken.tryParse] will even look at.
///
/// A pasted page is refused before it is cleaned rather than after: [_clean]
/// throws away everything that is not a letter or a digit, so a long enough
/// paste could otherwise be squeezed into something that happens to be twenty
/// valid characters.
const int kPairTokenMaxInput = 96;

/// The scheme and host of a link that carries a token, for the phone's deep
/// link handler. The token is the query, never the path: a link handler that
/// drops a fragment is common and one that drops a query is not.
const String kPairTokenLinkPrefix = 'grid://pair';

const String _docDomain = 'grid.phone.locator.doc.v1';
const String _keyDomain = 'grid.phone.locator.key.v1';

/// One phone's token, already known to be well formed.
class PairToken {
  const PairToken._(this.normalized);

  /// A new random token.
  ///
  /// [random] exists so a test can pin the bytes; production never passes it,
  /// and the default is [Random.secure] rather than [Random] — a guessable
  /// token is somebody else's computer.
  factory PairToken.generate({Random? random}) {
    final rng = random ?? Random.secure();
    final out = StringBuffer();
    for (var i = 0; i < kPairTokenLength; i++) {
      out.write(kPairTokenAlphabet[rng.nextInt(kPairTokenAlphabet.length)]);
    }
    return PairToken._(out.toString());
  }

  /// The token [raw] spells, or null when it does not spell one.
  ///
  /// Forgiving about *presentation* and strict about *content*: dashes, spaces
  /// and lower case are the shape a person types, and `O`/`I`/`L` are the
  /// characters they mean but cannot see, so all of those are corrected. A
  /// character that is neither — punctuation, a letter outside the alphabet —
  /// is a refusal, because silently dropping it would accept a token that is
  /// not the one on the other screen and fail two layers later as "your
  /// computer does not recognise this phone".
  static PairToken? tryParse(String raw) {
    if (raw.length > kPairTokenMaxInput) return null;
    final cleaned = _clean(raw);
    if (cleaned == null || cleaned.length != kPairTokenLength) return null;
    return PairToken._(cleaned);
  }

  /// The twenty characters, upper case and unpunctuated. This is the value that
  /// is stored and compared; [pretty] is only for reading.
  final String normalized;

  /// `XXXX-XXXX-XXXX-XXXX-XXXX` — how it is shown and copied.
  String get pretty {
    final groups = <String>[];
    for (var i = 0; i < normalized.length; i += 4) {
      groups.add(normalized.substring(i, i + 4));
    }
    return groups.join('-');
  }

  /// The document on the locator that holds this pairing's address.
  ///
  /// 32 hex characters, and the length is load-bearing: the Firestore rules
  /// admit a write only to an id of exactly this length, which is what stops
  /// anything else being written into the collection.
  String get locatorDocId => _digest(_docDomain).toString().substring(0, 32);

  /// The 32-byte key that document's contents are sealed with.
  Uint8List get locatorKey => Uint8List.fromList(_digest(_keyDomain).bytes);

  Digest _digest(String domain) =>
      sha256.convert(utf8.encode('$domain|$normalized'));

  /// The link that carries this token to a phone.
  String toLink() => '$kPairTokenLinkPrefix?token=$pretty';

  /// A value class, and a token is compared for equality all over this feature.
  @override
  bool operator ==(Object other) =>
      other is PairToken && other.normalized == normalized;

  @override
  int get hashCode => normalized.hashCode;

  /// Deliberately not the token. A token in a log line is a log line that
  /// reaches somebody's computer.
  @override
  String toString() => 'PairToken(…)';

  static String? _clean(String raw) {
    final out = StringBuffer();
    for (final ch in raw.toUpperCase().split('')) {
      switch (ch) {
        case '-':
        case ' ':
        case '\t':
        case '\n':
          continue;
        case 'O':
          out.write('0');
        case 'I':
        case 'L':
          out.write('1');
        default:
          if (!kPairTokenAlphabet.contains(ch)) return null;
          out.write(ch);
      }
    }
    return out.toString();
  }
}

/// The token text inside [raw], which may be a bare token or a `grid://pair`
/// link.
///
/// Both exist because both happen: somebody pastes the twenty characters, or
/// taps a link that carries them. Returning the *text* rather than a token
/// keeps one place deciding what a token is — [PairToken.tryParse].
String pairTokenTextOf(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.toLowerCase().startsWith('grid://')) return trimmed;
  final Uri parsed;
  try {
    parsed = Uri.parse(trimmed);
  } on FormatException {
    return '';
  }
  // Only this one route may carry a token. `grid://open?token=…` is a different
  // link and must not be read as a pairing.
  if (parsed.scheme != 'grid' || parsed.host != 'pair') return '';
  if (parsed.path.isNotEmpty && parsed.path != '/') return '';
  return parsed.queryParameters['token'] ?? '';
}
