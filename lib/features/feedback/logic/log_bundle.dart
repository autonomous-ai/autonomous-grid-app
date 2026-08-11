import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/logging/log_file.dart';

/// The log files, newest-of-today, that a feedback bundle attaches — the same
/// set the Debug tab's "Open logs" reveals, one file per base for today only.
///
/// Today, not the full fortnight the retention keeps: one day is enough to
/// reproduce what the user just hit, and it keeps the upload small. The engine's
/// own `llama_*.log` files are left out — they are the model server's, not the
/// app's, and rarely bear on an app bug.
const _bundledBases = [
  GridPaths.appLogBase, // app-…: narrative + uncaught stack traces
  GridPaths.cliLogBase, // app_cli-…: grid command argv + streamed output
  GridPaths.httpLogBase, // app_https-…: method + URL + status of each request
  GridPaths.nodeSetupLogBase, // app_node_setup-…: auto-install transcript
];

/// Per-file cap so one runaway day can't make the upload huge. 512 KB of text
/// per log is far more than a session's worth of lines; past it we keep the
/// *tail*, where the recent failure is.
const int _perFileClip = 512 * 1024;

/// One log file as it goes into the bundle: its name, and its redacted text.
///
/// [bytes] is the redacted content the file will carry — kept so the dialog can
/// show a size next to the name and, on request, the text itself. What the user
/// previews is exactly what is zipped.
class BundledLog {
  const BundledLog(this.name, this.text);

  final String name;
  final String text;

  int get bytes => utf8.encode(text).length;
}

/// A feedback log bundle: the files, and the zip built from them.
///
/// Both are here so the dialog can list what's inside (and let the user read it)
/// while the controller ships [zip] — the preview and the payload are built from
/// the one object, so they can never disagree about what leaves the machine.
class FeedbackLogBundle {
  const FeedbackLogBundle(this.files, this.zip);

  final List<BundledLog> files;

  /// The `application/zip` bytes, or empty when there was nothing to bundle
  /// (no logs today). The dialog treats empty as "nothing to attach".
  final Uint8List zip;

  bool get isEmpty => files.isEmpty;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.bytes);
}

/// Redacts anything in a log line that could be a secret, before it ever leaves
/// the machine.
///
/// The app doesn't log `Authorization` headers (the HTTP log records only method
/// and URL), but a bearer, an `sk-…` vendor key, or a `token = "…"` can still
/// reach a line through a command's own output or a URL's query — and a log that
/// travels off the device must not carry one. Conservative on purpose: it would
/// rather blank a harmless high-entropy string than let a real key through.
///
/// Pure, so what is scrubbed is decided by a function that can be tested rather
/// than by whatever the disk happens to hold.
String redactLogSecrets(String input) {
  var out = input;
  for (final rule in _redactions) {
    out = out.replaceAllMapped(rule.pattern, rule.replace);
  }
  return out;
}

typedef _Redaction = ({RegExp pattern, String Function(Match) replace});

final List<_Redaction> _redactions = [
  // `Bearer <token>` anywhere — the shape auth takes if it ever lands in output.
  (
    pattern: RegExp(r'(Bearer\s+)[A-Za-z0-9._\-]{8,}', caseSensitive: false),
    replace: (m) => '${m[1]}[redacted]',
  ),
  // Vendor keys with a well-known prefix (OpenAI `sk-…`, Anthropic `sk-ant-…`).
  (
    pattern: RegExp(r'\bsk-[A-Za-z0-9_\-]{8,}'),
    replace: (_) => 'sk-[redacted]',
  ),
  // `key = "…"`, `token: …`, `secret=…`, `password=…` — the value after any
  // secret-named field, however it's punctuated.
  (
    pattern: RegExp(
      r'''(["']?\b\w*(?:token|secret|password|api[_-]?key)\w*\b["']?\s*[:=]\s*["']?)([^\s"',}]{6,})''',
      caseSensitive: false,
    ),
    replace: (m) => '${m[1]}[redacted]',
  ),
  // A `?…token=…` or `?…key=…` inside a logged URL query.
  (
    pattern: RegExp(
      r'([?&][^=\s&]*(?:token|key|secret|sig|signature)[^=\s&]*=)[^\s&]+',
      caseSensitive: false,
    ),
    replace: (m) => '${m[1]}[redacted]',
  ),
];

/// Builds the zip from already-read, already-redacted [files]. Pure given its
/// input — the IO of reading the logs is [collectFeedbackLogs]'s job — so the
/// zipping is deterministic and reasoned about on its own.
Uint8List zipBundledLogs(List<BundledLog> files) {
  if (files.isEmpty) return Uint8List(0);
  final archive = Archive();
  for (final file in files) {
    final data = utf8.encode(file.text);
    archive.add(ArchiveFile(file.name, data.length, data));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// Reads today's app logs, redacts each, and zips them.
///
/// Best-effort throughout: a log that doesn't exist yet, or one that can't be
/// read, is simply left out rather than failing the whole bundle — an attached
/// bundle only ever *helps* a report, so a missing file is never worth blocking
/// the send over.
Future<FeedbackLogBundle> collectFeedbackLogs({DateTime? now}) async {
  final today = now ?? DateTime.now();
  final files = <BundledLog>[];
  for (final base in _bundledBases) {
    final name = dailyLogName(base, today);
    final file = File('${GridPaths.logsDir.path}/$name');
    try {
      if (!await file.exists()) continue;
      final raw = await _readClippedTail(file);
      if (raw.trim().isEmpty) continue;
      files.add(BundledLog(name, redactLogSecrets(raw)));
    } on Object {
      // Skip an unreadable file; the rest of the bundle still goes.
    }
  }
  return FeedbackLogBundle(files, zipBundledLogs(files));
}

/// The last [_perFileClip] bytes of [file], decoded leniently. A day's log can
/// outgrow the cap; the tail is where the failure being reported lives.
Future<String> _readClippedTail(File file) async {
  final handle = await file.open();
  try {
    final length = await handle.length();
    final from = length > _perFileClip ? length - _perFileClip : 0;
    if (from > 0) await handle.setPosition(from);
    final bytes = await handle.read(length - from);
    final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    // A clipped file starts mid-line; say so rather than presenting a fragment
    // as the whole thing.
    return from > 0 ? '…(earlier lines trimmed)\n$text' : text;
  } finally {
    await handle.close();
  }
}

/// The bundle for the open feedback dialog, gathered fresh (the logs move while
/// the dialog is open). A [FutureProvider] because reading the files is IO; it
/// never fails, so the dialog is never blocked by its own optional attachment.
final feedbackLogBundleProvider = FutureProvider<FeedbackLogBundle>(
  (ref) => collectFeedbackLogs(),
);
