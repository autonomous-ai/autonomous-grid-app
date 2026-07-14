import 'dart:io';

/// A `.env` file, as the tools the app drives actually read them.
///
/// Hermes (and Codex) keep their secrets in dotenv files, so the app has to
/// write into ones the user may already have. Every write **merges**: an existing
/// assignment is replaced in place, new keys are appended under a header naming
/// who added them, and every other line — including the user's comments — is kept
/// exactly as it was. The old file is copied to `<file>.bak` first.
class EnvFile {
  const EnvFile(this.file);

  final File file;

  /// The values assigned in the file. Commented-out template lines
  /// (`# TELEGRAM_BOT_TOKEN=`) are not assignments and don't count.
  Future<Map<String, String>> read() async {
    if (!await file.exists()) return const {};
    final values = <String, String>{};
    for (final line in await file.readAsLines()) {
      final match = _assignment.firstMatch(line);
      if (match == null) continue;
      values[match.group(1)!] = match.group(2)!.trim();
    }
    return values;
  }

  /// Upsert [vars]. [addedBy] names whoever the header credits when keys are new.
  Future<void> upsert(
    Map<String, String> vars, {
    required String addedBy,
  }) async {
    final lines = (await file.exists()) ? await file.readAsLines() : <String>[];
    final remaining = Map<String, String>.from(vars);
    final out = <String>[];

    for (final line in lines) {
      final key = remaining.keys.firstWhere(
        (k) => RegExp('^\\s*${RegExp.escape(k)}\\s*=').hasMatch(line),
        orElse: () => '',
      );
      if (key.isEmpty) {
        out.add(line);
        continue;
      }
      out.add('$key=${remaining.remove(key)}');
    }

    if (remaining.isNotEmpty) {
      if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
      out.add('# Added by Grid — $addedBy');
      remaining.forEach((k, v) => out.add('$k=$v'));
    }
    await _write(out);
  }

  /// Drop [keys] entirely. Used when the user disconnects something: leaving a
  /// dead token in the file would look connected to anyone who opened it.
  Future<void> remove(Set<String> keys) async {
    if (!await file.exists()) return;
    final out = [
      for (final line in await file.readAsLines())
        if (!keys.any(
          (k) => RegExp('^\\s*${RegExp.escape(k)}\\s*=').hasMatch(line),
        ))
          line,
    ];
    await _write(out);
  }

  Future<void> _write(List<String> lines) async {
    await file.parent.create(recursive: true);
    if (await file.exists()) await file.copy('${file.path}.bak');
    await file.writeAsString('${lines.join('\n')}\n');
  }
}

/// `KEY=value`, ignoring the commented-out examples every dotenv ships with.
final RegExp _assignment = RegExp(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$');
