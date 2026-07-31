import 'dart:convert';

/// The transformations a `rest_entry` request body may name, and nothing else.
///
/// **A closed set, on purpose.** The gateway describes what to send; it does not
/// get to describe *how to compute* it, because a general transform language in
/// a payload the app executes is a much larger thing than it looks. Every name
/// here is a published standard rather than one provider's quirk — Gmail's send
/// endpoint wants RFC 2822 in base64url because that is how mail is spelled, not
/// because Google invented something.
///
/// An unrecognised name is not ignored and not passed through: the tool that
/// asked for it is dropped, with a reason. Substituting an empty string would
/// send a syntactically valid request that does the wrong thing, which is the
/// worst of the available failures.
const Set<String> kRestEncoders = {'rfc2822_base64url', 'base64url'};

/// Apply [name] to the already-substituted [fields].
///
/// Throws [RestEncoderException] for an unknown name so the caller can turn it
/// into a tool error the user can read, rather than a silent wrong request.
String applyRestEncoder(String name, Map<String, Object?> fields) {
  switch (name) {
    case 'rfc2822_base64url':
      return _base64Url(utf8.encode(_rfc2822(fields)));
    case 'base64url':
      final value = fields['value'];
      return _base64Url(utf8.encode(value is String ? value : ''));
    default:
      throw RestEncoderException(name);
  }
}

class RestEncoderException implements Exception {
  const RestEncoderException(this.encoder);

  final String encoder;

  @override
  String toString() =>
      'This connector asked for an encoding this version of Grid does not '
      'know ("$encoder"). Update Grid, or ask support to check the connector.';
}

/// Build an RFC 2822 message from `to` / `subject` / `body`.
///
/// Everything is spelled out for UTF-8 because the users of this app write
/// Vietnamese: a raw non-ASCII `Subject:` header is not legal RFC 2822 and
/// arrives as mojibake, so it goes through RFC 2047 encoded-words, and the body
/// is declared `charset="UTF-8"` and base64-transferred rather than trusting
/// 8-bit to survive an intermediate relay.
String _rfc2822(Map<String, Object?> fields) {
  String field(String key) {
    final value = fields[key];
    return value is String ? value : '';
  }

  final body = field('body');
  final headers = <String>[
    'To: ${_headerValue(field('to'))}',
    if (field('cc').isNotEmpty) 'Cc: ${_headerValue(field('cc'))}',
    'Subject: ${_headerValue(field('subject'))}',
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset="UTF-8"',
    'Content-Transfer-Encoding: base64',
  ];
  // CRLF, not LF: the spec says so, and a bare LF is the kind of thing that
  // works against one server and is rejected by the next.
  return '${headers.join('\r\n')}\r\n\r\n${_wrap(base64.encode(utf8.encode(body)))}';
}

/// A header value safe to place on one line.
///
/// Non-ASCII becomes an RFC 2047 encoded-word. CR and LF are stripped first,
/// unconditionally: a newline inside a header is header injection, and the
/// values here are filled in by a language model from a user's sentence.
String _headerValue(String raw) {
  final clean = raw.replaceAll(RegExp(r'[\r\n]'), ' ').trim();
  if (clean.isEmpty) return '';
  final isAscii = clean.codeUnits.every((unit) => unit >= 32 && unit < 127);
  if (isAscii) return clean;
  return '=?UTF-8?B?${base64.encode(utf8.encode(clean))}?=';
}

/// Base64 lines wrap at 76 characters in a MIME body.
String _wrap(String encoded) {
  final buffer = StringBuffer();
  for (var i = 0; i < encoded.length; i += 76) {
    if (i > 0) buffer.write('\r\n');
    buffer.write(
      encoded.substring(i, i + 76 > encoded.length ? encoded.length : i + 76),
    );
  }
  return buffer.toString();
}

/// URL-safe base64 without padding, which is what `raw` fields expect.
String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');
