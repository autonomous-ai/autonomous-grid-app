/// One catalog row from `grid models list --catalog` (catalog.py:88).
/// Format: `  <label> <hf_repo>/<file> (<target?, >min <vram> GB, <kind>)`.
/// The catalog is hard-coded in the CLI, not on disk, so we parse it. See
/// CLI_Integration_Contract §3.3.
class CatalogEntry {
  const CatalogEntry({
    required this.label,
    required this.hfRepo,
    required this.quantizedFile,
    required this.minVramGb,
    required this.kind,
    this.target,
  });

  final String label;
  final String hfRepo;
  final String quantizedFile;
  final double minVramGb;
  final String kind;
  final String? target;

  static final RegExp _re = RegExp(
    r'^\s+(\S+)\s+(\S+)/(\S+)\s+\((?:(.+?),\s*)?min\s+([\d.]+)\s+GB,\s+(\w+)\)\s*$',
  );

  /// The `<repo>:<file>` spec accepted by `grid models pull`.
  String get pullSpec => '$hfRepo:$quantizedFile';

  static CatalogEntry? parse(String line) {
    final m = _re.firstMatch(line);
    if (m == null) return null;
    return CatalogEntry(
      label: m[1]!,
      hfRepo: m[2]!,
      quantizedFile: m[3]!,
      target: m[4],
      minVramGb: double.parse(m[5]!),
      kind: m[6]!,
    );
  }

  static List<CatalogEntry> parseAll(String stdout) =>
      stdout.split('\n').map(parse).whereType<CatalogEntry>().toList();
}
