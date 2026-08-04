import 'dart:convert';

import '../../../infrastructure/cli/command_log.dart';

/// Clock time of a logged command, `14:03:07`. The date is left off on purpose:
/// the list only ever holds this session.
String formatLogTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// How long a command took, in the shortest honest unit — `840ms`, `1.4s`, `62s`.
String formatLogDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  return '${(ms / 1000).toStringAsFixed(ms < 10000 ? 1 : 0)}s';
}

/// The `env` row for the parameters table: the names that were set, and the
/// plain statement that their values are not here. See [CommandDetail.envKeys].
String envNamesLabel(List<String> names) =>
    '${names.join(', ')} — values hidden';

/// The URL inside a summary line like `POST https://…/v1/chat/completions`, or
/// null when the line isn't one (a `grid …` command). Only the method + URL
/// shape is recognised, which is exactly what the HTTP call sites write.
Uri? logRequestUrl(GridCommandLog log) {
  if (log.kind != CliCallKind.http) return null;
  final parts = log.command.split(' ');
  if (parts.length < 2) return null;
  final url = Uri.tryParse(parts.last);
  return url != null && url.hasScheme ? url : null;
}

/// The HTTP method a request was issued with (`GET`, `POST`, …), or null for a
/// line that isn't a request.
String? logRequestMethod(GridCommandLog log) {
  if (log.kind != CliCallKind.http) return null;
  final method = log.command.split(' ').first;
  return method.toUpperCase() == method && method.isNotEmpty ? method : null;
}

/// The query string of an HTTP call, split into rows — `?json=true&limit=20`
/// reads as two facts rather than as tail noise on a long URL. Empty for a URL
/// that carries none.
Map<String, String> logQueryParams(GridCommandLog log) =>
    logRequestUrl(log)?.queryParameters ?? const {};

/// [body] re-printed with two-space indents when it is JSON, and returned
/// untouched when it isn't.
///
/// A request body arrives as one long line, and a one-line body is where a
/// wrong field hides. Non-JSON is common and not an error here — an agent turn
/// sends a plain prompt — so it is shown as it is rather than as a parse error.
String prettyBody(String body) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
  } on FormatException {
    return body;
  }
}

/// [value] as a single shell word: bare when it needs no quoting, in single
/// quotes otherwise (with any `'` of its own broken out and escaped).
///
/// Without this a grid named `My home grid` copies back as three arguments and
/// a JSON body ends the command halfway through. [always] quotes even a word
/// that would survive bare — a URL, where the `&` of a second query parameter
/// is the difference between one command and two.
String shellQuote(String value, {bool always = false}) {
  if (value.isEmpty) return "''";
  if (!always && RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(value)) {
    return value;
  }
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// The shell variable a copied request reads its bearer token from. Named, not
/// filled in: the key itself is never recorded (see [CommandDetail]).
const String kCopiedKeyVariable = 'GRID_API_KEY';

/// What the copy button offers for this entry, so the button says what it does.
String copyActionLabel(GridCommandLog log) {
  if (log.kind == CliCallKind.http) return 'Copy as curl';
  return log.detail.args.isEmpty ? 'Copy details' : 'Copy command';
}

/// The entry as something that can be pasted straight into a terminal: a `curl`
/// for a network request, the command line itself for anything the app spawned.
///
/// How it ended rides above it on `#` comment lines — a shell ignores those, so
/// one copy is both the thing to re-run and the thing to paste into a bug
/// report. An entry with nothing runnable behind it (a prompt sent over a
/// session that was already open) falls back to those facts alone.
String logAsCommand(GridCommandLog log) {
  final runnable = log.kind == CliCallKind.http
      ? _curl(log)
      : _shellCommand(log);
  final notes = [
    _outcomeLine(log),
    ...?_errorLines(log),
    ...?_warningLines(log, runnable != null),
  ];
  return [notes.join('\n'), runnable ?? _facts(log)].join('\n');
}

/// `# GET → 200 · 189ms · started 13:54:46`, the one line that says how it went.
String _outcomeLine(GridCommandLog log) {
  final lead = logRequestMethod(log) ?? log.detail.args.firstOrNull ?? 'ran';
  final outcome = switch (log.status) {
    CliCallStatus.running => 'still running',
    _ when log.exitCode != null =>
      log.kind == CliCallKind.http
          ? 'HTTP ${log.exitCode}'
          : 'exit ${log.exitCode}',
    CliCallStatus.failed => 'failed',
    CliCallStatus.success => 'ok',
  };
  final took = log.duration == null
      ? ''
      : ' · ${formatLogDuration(log.duration!)}';
  return '# $lead → $outcome$took · started ${formatLogTime(log.startedAt)}';
}

List<String>? _errorLines(GridCommandLog log) {
  final error = log.error;
  if (error == null) return null;
  return [for (final line in error.trim().split('\n')) '# $line'];
}

/// The two things that would otherwise make a copied command lie: a body that
/// was clipped before it got here, and a key that was deliberately not.
List<String>? _warningLines(GridCommandLog log, bool runnable) {
  if (!runnable) return null;
  final body = log.detail.requestBody;
  return [
    if (body != null && isClippedBody(body))
      '# NOTE: the body below was clipped for the log — it is not the whole one',
    if (log.detail.authorized)
      '# needs your key: export $kCopiedKeyVariable=… '
          '(never recorded here)',
    if (log.detail.envKeys.isNotEmpty)
      '# needs: ${log.detail.envKeys.join(', ')} '
          '(values never recorded here)',
  ];
}

/// The request as `curl`, or null when the line carries no URL to hit.
String? _curl(GridCommandLog log) {
  final url = logRequestUrl(log);
  if (url == null) return null;
  final method = logRequestMethod(log) ?? 'GET';
  final body = log.detail.requestBody;
  return [
    // `-sS` keeps the progress meter off the terminal but leaves errors on it.
    'curl -sS${method == 'GET' ? '' : ' -X $method'} '
        '${shellQuote('$url', always: true)}',
    if (body != null) "  -H 'Content-Type: application/json'",
    // Double-quoted, alone among these, so the shell expands the variable.
    if (log.detail.authorized)
      '  -H "Authorization: Bearer \$$kCopiedKeyVariable"',
    if (body != null) '  -d ${shellQuote(body)}',
  ].join(' \\\n');
}

/// The spawned process as a command line, or null when the entry records no
/// argv — a Hermes turn goes down a session that was already running, so there
/// is no command to re-run.
String? _shellCommand(GridCommandLog log) {
  final detail = log.detail;
  if (detail.args.isEmpty) return null;
  final command = [
    // `KEY="$KEY"` rather than the value: the copied line reads its secrets
    // from the terminal it is pasted into, exactly as the app did.
    for (final key in detail.envKeys) '$key="\$$key"',
    for (final arg in detail.args) shellQuote(arg),
  ].join(' ');
  final stdin = detail.requestBody;
  if (stdin == null) return command;
  // Both agents take their prompt on stdin, so a command without it would open
  // an empty turn. The opening tag is quoted and the closing one is not — that
  // is the shell's rule, and a quoted terminator never ends the document.
  return "$command <<'$kStdinHeredocTag'\n$stdin\n$kStdinHeredocTag";
}

/// The heredoc delimiter a copied command feeds its prompt through. Quoted at
/// the opening so the shell passes the prompt on as it is, `$`, backticks and
/// all — nothing in a prompt gets expanded on the way back in.
const String kStdinHeredocTag = 'GRID_PROMPT';

/// The facts alone, for an entry with no command behind it to run.
String _facts(GridCommandLog log) {
  final detail = log.detail;
  final params = {...logQueryParams(log), ...detail.params};
  return [
    '# ${log.command}',
    for (final entry in params.entries) '# ${entry.key}: ${entry.value}',
    if (detail.envKeys.isNotEmpty) '# env: ${envNamesLabel(detail.envKeys)}',
    if (detail.requestBody case final body?) '\n$body',
  ].join('\n');
}
