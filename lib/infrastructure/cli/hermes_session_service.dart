import 'dart:convert';
import 'dart:io';

import 'host_environment.dart';

/// Reads what Hermes knows about a chat session it ran.
///
/// Hermes names every session itself: a few seconds after the first reply it
/// writes a short line describing what the conversation is about ("Kiểm tra thư
/// mục dự án Flutter"), in the language the user wrote in. The app asks for that
/// name instead of inventing one from the raw first message — "hi" tells nobody
/// what a chat was for.
abstract interface class HermesSessionService {
  /// The name Hermes gave [sessionId], or null when it hasn't named it yet or
  /// the session can't be read. Safe to call repeatedly — it's a read.
  Future<String?> title(String sessionId);
}

/// Real implementation: spawns the `hermes` binary.
class HermesSessionServiceImpl implements HermesSessionService {
  const HermesSessionServiceImpl(this.binPath);

  /// Absolute path to the hermes binary (it isn't on a GUI app's default PATH).
  final String binPath;

  @override
  Future<String?> title(String sessionId) async {
    // `sessions export` streams the session as JSONL, and its *first* line is
    // the session record — the title among it. Reading that one line and killing
    // the process keeps a long transcript from being piped back for nothing.
    // Not mirrored into the command log: it's a local read the app repeats while
    // waiting for the name, and four identical lines per chat would just be
    // noise in there.
    final Process process;
    try {
      process = await Process.start(binPath, [
        'sessions',
        'export',
        '--session-id',
        sessionId,
        '--format',
        'jsonl',
        '--yes',
        '-',
      ], environment: HostEnvironment.hermesEnvironment());
    } on ProcessException {
      return null;
    }

    process.stderr.drain<void>().ignore();
    try {
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
      return parseSessionTitle(line);
    } on Object {
      return null;
    } finally {
      process.kill();
    }
  }
}

/// The title on a Hermes session record, or null when the line isn't one, or the
/// session hasn't been named yet.
String? parseSessionTitle(String jsonLine) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonLine);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final title = decoded['title'];
  if (title is! String) return null;
  final trimmed = title.trim();
  return trimmed.isEmpty ? null : trimmed;
}
