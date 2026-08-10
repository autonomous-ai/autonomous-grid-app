import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../playground/logic/chat_context.dart';
import '../../terminal/logic/terminal_capture.dart';
import '../../terminal/logic/terminal_sessions_controller.dart';

/// What [captureTerminalContexts] hands back, so a caller doesn't have to name
/// two files to send one thing.
export '../../playground/logic/chat_context.dart';

/// Re-exported so the chip can say how much of a terminal it is about to send
/// without the composer reaching into another feature to read the number.
export '../../terminal/logic/terminal_capture.dart' show kTerminalCaptureLines;

/// A terminal the next message will carry, as the composer knows it before Send.
///
/// The id, not the text: the shell is still running, so what is on screen now is
/// not what will be on screen when the message goes (see
/// [captureTerminalContexts]).
@immutable
class AttachedTerminal {
  const AttachedTerminal({required this.tabId, required this.label});

  /// The panel tab whose shell this is.
  final String tabId;

  /// What the chip says.
  final String label;
}

/// The terminals the user has put on the message they are typing.
///
/// **Asked for, never assumed.** This used to be derived — any terminal whose
/// panel was open and whose tab was in front rode along on the next message, and
/// the user's only say in it was a ✕ that had to be remembered separately or the
/// next frame put the chip straight back. Opening a terminal to look something
/// up is not the same as wanting a screenful of it quoted at a model, and the
/// app had no way to tell the two apart. Now the gesture says which: drag the
/// terminal's tab onto the conversation.
///
/// Cleared on Send, like every other part of a draft.
final attachedTerminalsProvider =
    NotifierProvider<AttachedTerminals, List<AttachedTerminal>>(
      AttachedTerminals.new,
    );

class AttachedTerminals extends Notifier<List<AttachedTerminal>> {
  @override
  List<AttachedTerminal> build() => const [];

  /// Put the terminal in tab [tabId] on this message.
  ///
  /// Dropping the same tab twice is the same one terminal, so it stays one chip
  /// rather than quietly sending the screen twice.
  void attach({required String tabId, required String label}) {
    if (state.any((terminal) => terminal.tabId == tabId)) return;
    state = List.unmodifiable([
      ...state,
      AttachedTerminal(tabId: tabId, label: label),
    ]);
  }

  /// Take it back off — the chip's ✕.
  void remove(String tabId) {
    if (!state.any((terminal) => terminal.tabId == tabId)) return;
    state = List.unmodifiable([
      for (final terminal in state)
        if (terminal.tabId != tabId) terminal,
    ]);
  }

  void clear() {
    if (state.isEmpty) return;
    state = const [];
  }
}

/// Reads [attached] out of [sessions] — called as Send is pressed, never
/// earlier.
///
/// The minute between attaching a terminal and asking about it is usually the
/// minute the thing being asked about happened: a build that was still running
/// when the chip appeared has failed by the time the message goes. Capturing at
/// Send is what makes the attachment worth having.
///
/// A terminal with nothing on it is left off entirely rather than sent as an
/// empty block — see [captureTerminal]. So is one whose tab has been closed
/// since it was attached: the session is gone, and there is nothing left to
/// read.
List<ChatContext> captureTerminalContexts({
  required List<AttachedTerminal> attached,
  required TerminalSessionsState sessions,
}) => [
  for (final terminal in attached)
    if (sessions[terminal.tabId] case final session?)
      if (captureTerminal(session.terminal) case final capture?)
        ChatContext(
          label: terminal.label,
          detail: session.workdir,
          text: capture.text,
          truncated: capture.truncated,
        ),
];
