import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/terminal/grid_terminal.dart';
import 'package:xterm/core.dart';

/// The dance `GridTerminal`'s doc records a real Codex session doing: pin a
/// block at the bottom, push it down, open a region above it, feed finished
/// lines up through it.
String codexTurn(int lines) {
  final out = StringBuffer();
  for (var i = 0; i < lines; i++) {
    out.write('\x1b[24;30r\x1b[24;1H\x1bM\x1bM');
    out.write('\x1b[r\x1b[1;25r\x1b[23;1H');
    out.write('\r\n  · a line of agent output number $i, long enough to be real');
    out.write('\x1b[r');
  }
  return out.toString();
}

int msFor(Terminal Function() make, String data, int reps) {
  final watch = Stopwatch()..start();
  for (var i = 0; i < reps; i++) {
    final t = make()..resize(110, 30);
    t.write(data);
  }
  watch.stop();
  return watch.elapsedMilliseconds;
}

void main() {
  test('bench', () {
    final turn = codexTurn(200);
    // ignore: avoid_print
    print('payload ${turn.length} chars, 200 scroll-region line feeds');
    for (final reps in [5]) {
      final grid = msFor(() => GridTerminal(maxLines: 10000), turn, reps);
      final stock = msFor(() => Terminal(maxLines: 10000), turn, reps);
      // ignore: avoid_print
      print('GridTerminal  ${grid}ms / $reps runs = ${grid / reps}ms per turn');
      // ignore: avoid_print
      print('stock xterm   ${stock}ms / $reps runs = ${stock / reps}ms per turn');
    }

    // Plain output, no scroll region — what `ls -R` or a build log looks like.
    final plain = StringBuffer();
    for (var i = 0; i < 2000; i++) {
      plain.write('lib/features/agents/logic/adapters/agent_$i.dart\r\n');
    }
    final g2 = msFor(() => GridTerminal(maxLines: 10000), plain.toString(), 5);
    final s2 = msFor(() => Terminal(maxLines: 10000), plain.toString(), 5);
    // ignore: avoid_print
    print('plain 2000 lines: GridTerminal ${g2 / 5}ms  stock ${s2 / 5}ms');
  });
}
