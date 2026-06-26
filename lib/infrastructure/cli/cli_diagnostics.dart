/// Turns raw `grid` CLI output into a clear, user-facing failure message:
/// [headline] plus the last line the CLI printed (where its error usually
/// lands), never the whole traceback.
String diagnoseCliFailure(Iterable<String> output, {required String headline}) {
  final lines = output.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return headline;
  return '$headline\n${lines.last}';
}
