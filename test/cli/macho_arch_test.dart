import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/macho_arch.dart';

/// A minimal thin 64-bit Mach-O header: little-endian `MH_MAGIC_64` followed by
/// [cputype] in the same byte order.
List<int> _thin(int cputype) => [
  0xCF, 0xFA, 0xED, 0xFE, // 0xFEEDFACF, on disk
  cputype & 0xFF,
  (cputype >> 8) & 0xFF,
  (cputype >> 16) & 0xFF,
  (cputype >> 24) & 0xFF,
];

/// A minimal fat/universal header: big-endian `FAT_MAGIC`, a slice count, then
/// one 20-byte `fat_arch` per [cputypes] (only the leading cputype word matters).
List<int> _fat(List<int> cputypes) => [
  0xCA, 0xFE, 0xBA, 0xBE, // FAT_MAGIC
  0, 0, 0, cputypes.length, // nfat_arch, big-endian
  for (final t in cputypes) ...[
    (t >> 24) & 0xFF, (t >> 16) & 0xFF, (t >> 8) & 0xFF, t & 0xFF, // cputype
    // rest of the 20-byte fat_arch (cpusubtype/offset/size/align), unread
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ],
];

const _x8664 = 0x01000007;
const _arm64 = 0x0100000C;

void main() {
  group('a thin Mach-O', () {
    test('runs on Intel when its one slice is x86_64', () {
      expect(machoRunsOnIntel(_thin(_x8664)), isTrue);
    });

    test('does not run on Intel when it is arm64-only — the shipped-wrong-arch '
        'sidecar the check exists to skip', () {
      expect(machoRunsOnIntel(_thin(_arm64)), isFalse);
    });
  });

  group('a fat/universal binary', () {
    test('runs on Intel when any slice is x86_64', () {
      expect(machoRunsOnIntel(_fat([_arm64, _x8664])), isTrue);
    });

    test('does not run on Intel when every slice is arm64', () {
      expect(machoRunsOnIntel(_fat([_arm64])), isFalse);
    });
  });

  group('anything we cannot vouch for falls open (null), never rejected', () {
    test('a file too short to be a Mach-O', () {
      expect(machoRunsOnIntel(const [0xCF, 0xFA]), isNull);
    });

    test('bytes that are not a Mach-O magic at all', () {
      expect(machoRunsOnIntel(const [1, 2, 3, 4, 5, 6, 7, 8]), isNull);
    });

    test(
      'a fat header that claims more slices than the bytes we read hold',
      () {
        // Says 9 slices but carries only the 8-byte header — unreadable, so the
        // caller must keep the binary rather than guess.
        expect(
          machoRunsOnIntel(const [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 9]),
          isNull,
        );
      },
    );
  });
}
