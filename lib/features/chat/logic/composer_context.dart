import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../playground/logic/chat_context.dart';
import '../../terminal/logic/terminal_capture.dart';
import '../../terminal/logic/terminal_sessions_controller.dart';
import 'bottom_panel.dart';
import 'panel_tabs.dart';
import 'preview_panel.dart';

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

/// The terminals the user is looking at — nothing else.
///
/// Derived rather than a list anybody adds to, because "the terminal I'm looking
/// at" is a fact about the panels, not a choice: a panel has to be open and its
/// active tab has to be the terminal. That is what caps this at two — one panel
/// beside the conversation, one under it — with no counting anywhere.
///
/// A terminal hidden behind another tab doesn't count, even though its shell is
/// very much alive. The rule is what the user can see, so that the chips can be
/// checked against the screen rather than remembered.
final attachedTerminalsProvider = Provider<List<AttachedTerminal>>((ref) {
  final dismissed = ref.watch(dismissedTerminalsProvider);
  final showing = <(PanelHost, PanelTab)>[];
  for (final host in PanelHost.values) {
    final open = switch (host) {
      PanelHost.preview => ref.watch(previewPanelOpenProvider),
      PanelHost.bottom => ref.watch(bottomPanelOpenProvider),
    };
    if (!open) continue;
    final tab = ref.watch(panelTabsProvider(host)).active;
    if (tab == null || tab.feature != PanelFeature.terminal) continue;
    if (dismissed.contains(tab.id)) continue;
    showing.add((host, tab));
  }

  // Both panels number their tabs from one, so two terminals on screen are
  // usually both called "Terminal". Say which panel only when there are two of
  // them — on its own, "Terminal · side" is a detail nobody asked for.
  return List.unmodifiable([
    for (final (host, tab) in showing)
      AttachedTerminal(
        tabId: tab.id,
        label: showing.length == 1
            ? tab.title
            : '${tab.title} · ${_panelWord(host)}',
      ),
  ]);
});

/// The terminals the user took off the message they are typing.
///
/// This exists because the chips are derived: with nothing remembering the ✕,
/// the next frame would put the chip straight back. The dismissal belongs to the
/// draft rather than to the tab, so [clear] runs on Send and the terminal is
/// offered again for the next message.
final dismissedTerminalsProvider =
    NotifierProvider<DismissedTerminals, Set<String>>(DismissedTerminals.new);

class DismissedTerminals extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void dismiss(String tabId) => state = {...state, tabId};

  void clear() {
    if (state.isEmpty) return;
    state = const {};
  }
}

/// Reads [attached] out of [sessions] — called as Send is pressed, never
/// earlier.
///
/// The minute between opening a terminal and asking about it is usually the
/// minute the thing being asked about happened: a build that was still running
/// when the chip appeared has failed by the time the message goes. Capturing at
/// Send is what makes the attachment worth having.
///
/// A terminal with nothing on it is left off entirely rather than sent as an
/// empty block — see [captureTerminal].
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

String _panelWord(PanelHost host) => switch (host) {
  PanelHost.preview => 'side',
  PanelHost.bottom => 'bottom',
};
