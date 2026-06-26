/// Turns raw `grid` CLI output into a clear, user-facing failure message.
///
/// Surfaces a known, actionable cause when one is recognisable — today the
/// arm64/x86_64 native-extension mismatch that happens when the app or CLI runs
/// under Rosetta — otherwise returns [headline] plus the last line the CLI
/// printed (where its error usually lands), never the whole traceback.
String diagnoseCliFailure(Iterable<String> output, {required String headline}) {
  final lines = output.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return headline;
  final joined = lines.join('\n');
  if (joined.contains('incompatible architecture') ||
      (joined.contains('ImportError') && joined.contains('mach-o'))) {
    return 'The grid CLI failed to start — architecture mismatch '
        '(arm64 vs x86_64). Run the app and CLI natively, not under Rosetta.';
  }
  return '$headline\n${lines.last}';
}
