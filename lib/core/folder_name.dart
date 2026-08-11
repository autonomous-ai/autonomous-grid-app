/// Naming things after the folder somebody picked.
///
/// In `lib/core` because two features do it: a Home project (a folder the
/// assistant reads) and a Code project (a repository copied onto the grid).
/// One importing the other's logic is the dependency §1 forbids, and a
/// second copy would be free to disagree about Windows paths.
library;

/// The last segment of a path — what a person calls the folder.
///
/// Splits on both separators: a Windows path arrives with backslashes, and
/// taking the last `/` segment of `C:\Users\me\proj` returns the whole string —
/// a project named with an absolute path rather than a folder.
String folderName(String path) {
  final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}
