import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/terminal/logic/terminal_capture.dart';
import 'package:xterm/xterm.dart';

/// Writes [lines] to [terminal] the way a shell does — CR then LF, because a
/// pty's newline doesn't return the cursor on its own.
void _type(Terminal terminal, List<String> lines) {
  for (final line in lines) {
    terminal.write('$line\r\n');
  }
}

void main() {
  test('a terminal nobody has typed into carries nothing', () {
    // The case that matters: a tab opened a second ago is a prompt and a screen
    // of blank rows, and a message claiming to carry that lies about what the
    // assistant can see.
    expect(captureTerminal(Terminal()), isNull);
  });

  test('what is on screen comes back without the blank rows around it', () {
    final terminal = Terminal();
    _type(terminal, ['\$ flutter test', 'All tests passed!']);

    final capture = captureTerminal(terminal);

    expect(capture?.text, '\$ flutter test\nAll tests passed!');
    expect(capture?.truncated, isFalse);
  });

  test('a long run keeps its end, where the failure is', () {
    final terminal = Terminal(maxLines: 5000);
    _type(terminal, [
      for (var i = 1; i <= 400; i++) 'step $i',
      'Error: could not find a device',
    ]);

    final capture = captureTerminal(terminal, maxLines: 10);

    expect(capture!.text.split('\n'), hasLength(10));
    expect(capture.text, endsWith('Error: could not find a device'));
    expect(capture.text, contains('step 400'));
    expect(capture.text, isNot(contains('step 390')));
  });

  test('a capture that starts part-way in says so', () {
    // The message admits what it left out, so an agent that needs the rest asks
    // for it instead of answering from half a log.
    final terminal = Terminal(maxLines: 5000);
    _type(terminal, [for (var i = 1; i <= 400; i++) 'step $i']);

    expect(captureTerminal(terminal, maxLines: 10)?.truncated, isTrue);
  });

  test('the blank screen under the cursor never eats the output', () {
    // Asking for the buffer's last N rows would hand back the empty ones below
    // the prompt: a terminal is 24 rows tall whether or not it is full.
    final terminal = Terminal(maxLines: 5000);
    _type(terminal, [for (var i = 1; i <= 400; i++) 'step $i']);

    final capture = captureTerminal(terminal, maxLines: 3);

    expect(capture?.text, 'step 398\nstep 399\nstep 400');
  });

  test('a wide screenful is cut to a size a prompt can carry', () {
    final terminal = Terminal(maxLines: 5000);
    _type(terminal, [for (var i = 0; i < 50; i++) 'x' * 60]);

    final capture = captureTerminal(terminal, maxChars: 500);

    expect(capture!.text.length, lessThanOrEqualTo(500));
    expect(capture.truncated, isTrue);
  });
}
