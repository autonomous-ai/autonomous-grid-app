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

/// The whole entry as plain text, for the dialog's copy action: the command,
/// how it ended, and every recorded argument and body. This is what someone
/// pastes into a bug report, so it repeats what is already on screen rather
/// than assuming a screenshot came with it.
String logAsText(GridCommandLog log) {
  final out = StringBuffer()
    ..writeln(log.command)
    ..writeln('kind: ${log.kind.name}')
    ..writeln('started: ${formatLogTime(log.startedAt)}');
  if (log.duration case final d?) out.writeln('took: ${formatLogDuration(d)}');
  if (log.exitCode case final code?) {
    out.writeln(log.kind == CliCallKind.http ? 'status: $code' : 'exit: $code');
  }
  if (log.error case final error?) out.writeln('error: $error');

  final detail = log.detail;
  if (detail.args.isNotEmpty) {
    out.writeln('\narguments:');
    for (final arg in detail.args) {
      out.writeln('  $arg');
    }
  }
  final params = {...logQueryParams(log), ...detail.params};
  if (params.isNotEmpty) {
    out.writeln('\nparameters:');
    params.forEach((key, value) => out.writeln('  $key: $value'));
  }
  if (detail.requestBody case final body?) {
    out.writeln('\nrequest:\n${prettyBody(body)}');
  }
  if (detail.responseBody case final body?) {
    out.writeln('\nresponse:\n$body');
  }
  return out.toString();
}
