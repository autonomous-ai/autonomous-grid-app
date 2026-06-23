/// One row of `grid network denylist list` (cli.py:669).
/// Format: `email \t by=<email> \t at=<timestamp>`.
/// See CLI_Integration_Contract §3.2.
class DenylistEntry {
  const DenylistEntry({
    required this.email,
    required this.addedByEmail,
    required this.addedAt,
  });

  final String email;
  final String addedByEmail;
  final String addedAt;

  static DenylistEntry? parse(String line) {
    final parts = line.split('\t');
    if (parts.length < 3) return null;
    return DenylistEntry(
      email: parts[0],
      addedByEmail: parts[1].replaceFirst('by=', ''),
      addedAt: parts[2].replaceFirst('at=', ''),
    );
  }

  static List<DenylistEntry> parseAll(String stdout) =>
      stdout.split('\n').map(parse).whereType<DenylistEntry>().toList();
}
