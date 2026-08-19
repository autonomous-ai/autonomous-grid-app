/// What one person on a grid ran inside the relay's answered window, parsed from
/// `GET {relayBaseUrl}/grid/members/usage`.
///
/// The consumer-side sibling of [NodeAnswered]: that one answers "which machine
/// did the work", this one "who asked for it". Same four figures, same window,
/// and the same rule binding them — see [tokensCached].
class MemberUsage {
  const MemberUsage({
    required this.email,
    this.requests = 0,
    this.tokensIn = 0,
    this.tokensCached = 0,
    this.tokensOut = 0,
  });

  /// Who this is. The relay resolves it from its own identity table, and a
  /// consumer whose row is missing yields null rather than being dropped — usage
  /// nobody can name is still usage, and hiding it would stop the figures adding
  /// up against the grid total.
  final String? email;

  final int requests;

  /// Everything read, cached prefill included.
  final int tokensIn;

  /// The cached share **of [tokensIn]**, never additional to it. Billing is
  /// explicit about this — cost is `(in − cached)·input + cached·cache +
  /// out·output` — so anything splitting this three ways must use
  /// [freshInputTokens] as the input leg or it will show a person three figures
  /// summing to more than they used.
  final int tokensCached;

  final int tokensOut;

  /// Input that was not served from a prompt cache — the leg that, with cache
  /// and output, adds up to what passed through.
  int get freshInputTokens => tokensIn - tokensCached;

  /// Everything that passed through: read plus written. Cache is inside
  /// [tokensIn] already, so adding it here would count the cached prefill twice.
  int get totalTokens => tokensIn + tokensOut;

  /// Null when the row is not an object — a payload shape we don't understand,
  /// dropped rather than guessed at. Every field is tolerant of absence so a
  /// relay that grows a fifth figure doesn't break the four we know.
  static MemberUsage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, dynamic>();
    final tokensIn = _int(json['tokens_in']);
    return MemberUsage(
      email: json['email'] as String?,
      requests: _int(json['requests']),
      tokensIn: tokensIn,
      // Clamped to the input it is part of, the way the relay stores it. A
      // provider bug or an old row would otherwise hand the UI a negative
      // fresh-input leg and a bar drawn past its own track.
      tokensCached: _int(json['tokens_cached']).clamp(0, tokensIn),
      tokensOut: _int(json['tokens_out']),
    );
  }

  /// Type-checked rather than cast: this reaches the app from a relay, and a
  /// string where a number belongs would throw mid-parse and cost the whole
  /// panel instead of one row's figures.
  static int _int(Object? value) => value is num ? value.toInt() : 0;

  @override
  bool operator ==(Object other) =>
      other is MemberUsage &&
      other.email == email &&
      other.requests == requests &&
      other.tokensIn == tokensIn &&
      other.tokensCached == tokensCached &&
      other.tokensOut == tokensOut;

  @override
  int get hashCode =>
      Object.hash(email, requests, tokensIn, tokensCached, tokensOut);
}
