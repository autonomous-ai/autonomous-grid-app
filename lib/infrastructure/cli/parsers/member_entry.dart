/// One row of `grid network allowlist list` (cli.py:634).
/// Format: `email \t status \t role1,role2 \t epoch=N`.
/// Allowlist data lives at the control plane (not on disk), so parsing the CLI
/// output is the only way to read it. See CLI_Integration_Contract §3.1.
class MemberEntry {
  const MemberEntry({
    required this.email,
    required this.status,
    required this.roles,
    required this.memberEpoch,
  });

  final String email;
  final String status;
  final List<String> roles;
  final int memberEpoch;

  /// Returns null on any malformed line — callers keep raw text and degrade
  /// rather than throw.
  static MemberEntry? parse(String line) {
    final parts = line.split('\t');
    if (parts.length < 4) return null;
    return MemberEntry(
      email: parts[0],
      status: parts[1],
      roles: parts[2].isEmpty ? const [] : parts[2].split(','),
      memberEpoch: int.tryParse(parts[3].replaceFirst('epoch=', '')) ?? 0,
    );
  }

  static List<MemberEntry> parseAll(String stdout) =>
      stdout.split('\n').map(parse).whereType<MemberEntry>().toList();
}
