/// Pure Mach-O header reading, so the resolver can tell whether a bundled `grid`
/// sidecar can actually run on this Mac before it hands it back.
///
/// The bug this exists for: an Intel (x86_64) release that ships an arm64-only
/// sidecar. On a real Intel Mac there is no reverse-Rosetta, so every spawn dies
/// with "Bad CPU type in executable" — and because the bundled binary is tried
/// before the system one ([GridResolver]), a perfectly good `~/.local/bin/grid`
/// stays shadowed by the broken bundle. Reading the header lets us skip a sidecar
/// we know this CPU can't execute and fall through to one it can.
library;

/// `CPU_TYPE_X86_64` from `<mach/machine.h>` — the one slice an Intel Mac runs.
const int _cpuTypeX8664 = 0x01000007;

int _u32be(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _u32le(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// Whether [header] — the leading bytes of a Mach-O executable — carries a slice
/// an Intel (x86_64) Mac can execute.
///
/// Returns `true` when an x86_64 slice is present, `false` when it's a Mach-O we
/// understood that has none (e.g. an arm64-only binary), and `null` when [header]
/// isn't a Mach-O we can read. Callers **fall open** on `null`: a file we failed
/// to parse is kept, never rejected — the check only ever removes a binary we're
/// sure this CPU can't run.
bool? machoRunsOnIntel(List<int> header) {
  if (header.length < 8) return null;

  // The first four bytes read big-endian give the on-disk magic pattern directly
  // for every variant we care about.
  final magic = _u32be(header, 0);

  // Thin Mach-O, little-endian (all modern x86_64/arm64 binaries): the cputype
  // is the next word, in the file's own (little-endian) byte order.
  if (magic == 0xCFFAEDFE || magic == 0xCEFAEDFE) {
    return _u32le(header, 4) == _cpuTypeX8664;
  }

  // Fat/universal binary: a big-endian header with one cputype per slice. Runs
  // on Intel if any slice is x86_64.
  if (magic == 0xCAFEBABE || magic == 0xCAFEBABF) {
    final wideEntries = magic == 0xCAFEBABF; // fat_arch_64 vs fat_arch
    final count = _u32be(header, 4);
    final stride = wideEntries ? 32 : 20;
    var offset = 8;
    for (var i = 0; i < count; i++) {
      // Truncated header (we only read the first block of the file): can't be
      // sure, so fall open rather than reject.
      if (offset + 4 > header.length) return null;
      if (_u32be(header, offset) == _cpuTypeX8664) return true;
      offset += stride;
    }
    return false;
  }

  // Big-endian thin Mach-O (PPC-era) or something that isn't Mach-O at all —
  // not a case our sidecars hit, so don't second-guess it.
  return null;
}
