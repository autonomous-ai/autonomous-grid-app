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
///
/// [onProgress] is called as bytes land, with the total when the server sent a
/// `Content-Length` and null when it didn't. It fires per chunk — thousands of
/// times on a 60 MB archive — so a caller that puts it on screen has to throttle
/// it. Without this the only honest thing an installer could show for a minute
/// was a spinner, which reads the same whether it is downloading or hung.
Future<File> downloadToFile(
  Uri url,
  Directory dir, {
  void Function(int received, int? total)? onProgress,
}) async {
  final dest = File('${dir.path}/${_basename(url.path)}');
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    // Honour `http_proxy`/`https_proxy`/`no_proxy`. Without this a managed
    // machine can't reach GitHub at all, and the install fails at the socket
    // with an error that names the CDN rather than the proxy that blocked it.
    ..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw AgentDownloadException(
        'Download failed (${response.statusCode}): $url',
      );
    }
    // -1 when the server didn't say; passed on as null rather than as a total
    // of -1, so a caller can't accidentally render "24 of -1 MB".
    final total = response.contentLength < 0 ? null : response.contentLength;
    var received = 0;
    final sink = dest.openWrite();
    final body = onProgress == null
        ? response
        : response.map((chunk) {
            received += chunk.length;
            onProgress(received, total);
            return chunk;
          });
    await body.pipe(sink).timeout(kDownloadTimeout);
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
///
/// Symbolic links are recreated rather than skipped. A single-binary release
/// doesn't have any, but a whole toolchain does and depends on them: Git ships
/// 145 of them under `libexec/git-core`, one of which is
/// `git-remote-https -> git-remote-http`. Drop those and `git clone` over HTTPS
/// fails with `'remote-https' is not a git command` — a failure that looks like a
/// broken download rather than a lossy unpack. Link targets are held to the same
/// containment rule as paths.
///
/// The executable bit is carried over for the same reason: a binary unpacked
/// without it can't be run, and the caller can't tell which of hundreds of
/// entries were meant to be programs.
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
  final executables = <String>[];
  for (final entry in unpacked) {
    final target = File('$root/${entry.name}');
    if (!target.absolute.path.startsWith('$root/')) {
      throw AgentDownloadException(
        'Refusing unsafe archive path: ${entry.name}',
      );
    }
    // Checked before `isFile`: a link entry can carry either flag depending on
    // the archive format, and writing its target string as file content would
    // leave a plausible-looking stub that fails only when something runs it.
    if (entry.isSymbolicLink) {
      await _restoreLink(entry, target, root);
      continue;
    }
    if (!entry.isFile) continue;
    await target.parent.create(recursive: true);
    await target.writeAsBytes(entry.readBytes() ?? const []);
    if (entry.mode & 0x49 != 0) executables.add(target.path);
  }
  await _makeExecutable(executables);
}

/// Recreate one symlink from [entry], refusing a target that would reach outside
/// [root]. An absolute target is refused outright — nothing in a relocatable
/// toolchain should point at a fixed path on the machine it lands on.
Future<void> _restoreLink(ArchiveFile entry, File target, String root) async {
  final to = entry.symbolicLink ?? '';
  if (to.isEmpty) return;
  final resolved = File('${target.parent.path}/$to').absolute.path;
  if (to.startsWith('/') || !_within(resolved, root)) {
    throw AgentDownloadException(
      'Refusing unsafe archive link: ${entry.name} -> $to',
    );
  }
  await target.parent.create(recursive: true);
  final link = Link(target.path);
  if (await link.exists()) await link.delete();
  if (target.existsSync()) await target.delete();
  await link.create(to);
}

/// Whether [path] stays inside [root] once `..` segments are folded out.
bool _within(String path, String root) {
  final parts = <String>[];
  for (final segment in path.split('/')) {
    if (segment == '.' || segment.isEmpty) continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  return '/${parts.join('/')}'.startsWith(root);
}

/// One `chmod` for every executable in the archive — spawning it per file costs
/// more than the unpack itself on a tree of a few hundred entries.
Future<void> _makeExecutable(List<String> paths) async {
  if (paths.isEmpty || Platform.isWindows) return;
  await Process.run('chmod', ['0755', ...paths]);
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
