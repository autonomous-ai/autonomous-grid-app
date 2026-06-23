/// Progress of `grid models pull` / `grid media pull`, parsed from the CLI's
/// hand-rolled stderr bar (download.py:82). The bar is `\r`-delimited (carriage
/// return, not newline) and comes in two shapes:
///   * total known:   `[####----]    123.4 / 456.7 MB ( 27.0%)`
///   * total unknown: `123.4 MB`
/// See CLI_Integration_Contract §3.4. This is the single genuinely fragile
/// parser — on a miss, callers fall back to an indeterminate spinner.
class DownloadProgress {
  const DownloadProgress({
    required this.doneMb,
    this.totalMb,
    this.pct,
  });

  final double doneMb;
  final double? totalMb;
  final double? pct;

  bool get isIndeterminate => pct == null;

  static final RegExp _full =
      RegExp(r'([\d.]+)\s*/\s*([\d.]+)\s*MB\s*\(\s*([\d.]+)%\)');
  static final RegExp _mbOnly = RegExp(r'([\d.]+)\s*MB');

  /// [chunk] is one segment after splitting the raw stderr on `\r`.
  static DownloadProgress? parse(String chunk) {
    final full = _full.firstMatch(chunk);
    if (full != null) {
      return DownloadProgress(
        doneMb: double.parse(full[1]!),
        totalMb: double.parse(full[2]!),
        pct: double.parse(full[3]!),
      );
    }
    final mb = _mbOnly.firstMatch(chunk);
    if (mb == null) return null;
    return DownloadProgress(doneMb: double.parse(mb[1]!));
  }

  /// Parse the latest progress from a raw stderr blob (keeps only the freshest
  /// `\r` segment that yields a value).
  static DownloadProgress? latest(String rawStderr) {
    final segments = rawStderr.split('\r');
    for (final segment in segments.reversed) {
      final parsed = parse(segment);
      if (parsed != null) return parsed;
    }
    return null;
  }
}
