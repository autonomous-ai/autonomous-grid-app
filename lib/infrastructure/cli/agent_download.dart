import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Raised when a fetched archive doesn't match its pinned hash, can't be
/// unpacked, or won't download — the one wall between a network fetch and code
/// the app then executes.
class AgentDownloadException implements Exception {
  const AgentDownloadException(this.message);
  final String message;

  @override
  String toString() => 'AgentDownloadException: $message';
}

/// How long the whole download may take before it's given up on — generous
/// (a private CPython or a release archive is tens of MB) but not unbounded.
const Duration kDownloadTimeout = Duration(minutes: 10);

/// Stream [url] to a file under [dir], following redirects (GitHub release URLs
/// bounce to a CDN). Throws [AgentDownloadException] on anything but 200, and
/// on a transfer that outstays [kDownloadTimeout] — a stalled connection would
/// otherwise leave an install spinning with nothing behind it.
Future<File> downloadToFile(Uri url, Directory dir) async {
  final dest = File('${dir.path}/${_basename(url.path)}');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw AgentDownloadException(
        'Download failed (${response.statusCode}): $url',
      );
    }
    final sink = dest.openWrite();
    await response.pipe(sink).timeout(kDownloadTimeout);
    return dest;
  } on AgentDownloadException {
    rethrow;
  } on TimeoutException {
    throw AgentDownloadException(
      'Download timed out after ${kDownloadTimeout.inMinutes} minutes: $url',
    );
  } on Object catch (error) {
    throw AgentDownloadException("Couldn't download $url: $error");
  } finally {
    client.close(force: true);
  }
}

/// Verify [file] against its pinned [expected] SHA-256 (lower-case hex), throwing
/// on a mismatch — the hash mirrors the CLI's, so a mismatch means either a
/// corrupt download or a pin that has drifted from the release it names.
Future<void> verifySha256(File file, String expected) async {
  final digest = sha256.convert(await file.readAsBytes()).toString();
  if (digest != expected.toLowerCase()) {
    throw AgentDownloadException(
      'SHA-256 mismatch for ${_basename(file.path)}: expected $expected, got '
      '$digest',
    );
  }
}

/// Unpack [archive] (`.tar.gz`/`.tgz` or `.zip`) into [dest], refusing any entry
/// that would write outside it (`..`, an absolute path) — the archive was just
/// fetched over the network, so it is not trusted to stay in its own directory.
Future<void> extractArchive(File archive, Directory dest) async {
  final bytes = await archive.readAsBytes();
  final name = _basename(archive.path).toLowerCase();
  final Archive unpacked;
  if (name.endsWith('.zip')) {
    unpacked = ZipDecoder().decodeBytes(bytes);
  } else if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) {
    unpacked = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
  } else if (name.endsWith('.tar')) {
    unpacked = TarDecoder().decodeBytes(bytes);
  } else {
    throw AgentDownloadException('Unsupported archive type: $name');
  }

  await dest.create(recursive: true);
  final root = dest.absolute.path;
  for (final entry in unpacked) {
    if (!entry.isFile) continue;
    final target = File('$root/${entry.name}');
    if (!target.absolute.path.startsWith('$root/')) {
      throw AgentDownloadException(
        'Refusing unsafe archive path: ${entry.name}',
      );
    }
    await target.parent.create(recursive: true);
    await target.writeAsBytes(entry.readBytes() ?? const []);
  }
}

/// Copy [source] to [target] and make it runnable (no-op chmod on Windows),
/// replacing whatever was there. Returns [target].
Future<File> installBinary(File source, File target) async {
  await target.parent.create(recursive: true);
  if (await target.exists()) await target.delete();
  await source.copy(target.path);
  if (!Platform.isWindows) {
    await Process.run('chmod', ['0755', target.path]);
  }
  return target;
}

/// The largest file under [root] whose name starts with [prefix] (case-insensitive)
/// — how a release binary is found inside an extracted archive when its exact
/// name varies between versions (the binary dwarfs any bundled README/licence).
/// Prefers an exact [prefix] match, and on Windows an `.exe`.
File? locateBinary(Directory root, String prefix) {
  final matches = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => _basename(f.path).toLowerCase().startsWith(prefix))
      .toList();
  if (matches.isEmpty) return null;
  final wanted = Platform.isWindows ? '$prefix.exe' : prefix;
  for (final file in matches) {
    if (_basename(file.path).toLowerCase() == wanted) return file;
  }
  if (Platform.isWindows) {
    final exes = matches
        .where((f) => f.path.toLowerCase().endsWith('.exe'))
        .toList();
    if (exes.isNotEmpty) {
      exes.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      return exes.first;
    }
  }
  matches.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
  return matches.first;
}

String _basename(String path) => path.split(RegExp(r'[/\\]')).last;
