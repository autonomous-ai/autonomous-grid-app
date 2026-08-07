import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/bottom_panel.dart';
import 'package:grid_app/features/chat/logic/composer_context.dart';
import 'package:grid_app/features/chat/logic/panel_tabs.dart';
import 'package:grid_app/features/terminal/logic/terminal_session.dart';
import 'package:grid_app/features/terminal/logic/terminal_sessions_controller.dart';

void main() {
  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        // No real shell: what's under test is which terminals the composer
        // offers, and spawning a login shell per case would make it slow and
        // machine-dependent for nothing.
        shellStarterProvider.overrideWithValue((session, onError) {}),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Opens a tab in [host] and returns its id — [PanelTabs.open] opens the panel
  /// too, so this is also how a panel gets on screen.
  String open(ProviderContainer c, PanelHost host, PanelFeature feature) =>
      c.read(panelTabsProvider(host).notifier).open(feature);

  test('a chat with no panel open carries no terminal', () {
    expect(container().read(attachedTerminalsProvider), isEmpty);
  });

  test('the terminal on screen is offered with the next message', () {
    // The whole feature in one line: open a terminal, and the assistant is
    // asked about what you are looking at without you pasting anything.
    final c = container();
    final id = open(c, PanelHost.preview, PanelFeature.terminal);

    final attached = c.read(attachedTerminalsProvider);

    expect(attached, hasLength(1));
    expect(attached.single.tabId, id);
    expect(attached.single.label, 'Terminal');
  });

  test('two panels showing terminals say which is which', () {
    // Both panels number their tabs from one, so without the panel in the label
    // this is two identical chips and no way to tell what will be sent.
    final c = container();
    open(c, PanelHost.preview, PanelFeature.terminal);
    open(c, PanelHost.bottom, PanelFeature.terminal);

    final labels = [for (final t in c.read(attachedTerminalsProvider)) t.label];

    expect(labels, ['Terminal · side', 'Terminal · bottom']);
  });

  test('a terminal behind another tab is not something you are looking at', () {
    // It is still running, and the user can still see the panel — but what is in
    // front of them is a file browser, so the chip would be a claim about a
    // screen nobody is reading.
    final c = container();
    open(c, PanelHost.preview, PanelFeature.terminal);
    open(c, PanelHost.preview, PanelFeature.files);

    expect(c.read(attachedTerminalsProvider), isEmpty);
  });

  test('closing the panel takes the offer with it', () {
    final c = container();
    open(c, PanelHost.bottom, PanelFeature.terminal);

    c.read(bottomPanelOpenProvider.notifier).close();

    expect(c.read(attachedTerminalsProvider), isEmpty);
  });

  test('✕ drops the terminal from this message, not from the next one', () {
    // The chips are derived, so without the dismissal being remembered the next
    // frame puts the chip straight back — and without it being *forgotten* on
    // Send, one ✕ would silence that terminal for the rest of the conversation.
    final c = container();
    final id = open(c, PanelHost.preview, PanelFeature.terminal);

    c.read(dismissedTerminalsProvider.notifier).dismiss(id);
    expect(c.read(attachedTerminalsProvider), isEmpty);

    c.read(dismissedTerminalsProvider.notifier).clear();
    expect(c.read(attachedTerminalsProvider), hasLength(1));
  });

  test('what is sent is the terminal as it reads at Send, with its folder', () {
    final session = TerminalSession(id: 'preview-tab-1', workdir: '/me/Musiky');
    session.terminal.write('\$ flutter run\r\nNo devices found.\r\n');

    final contexts = captureTerminalContexts(
      attached: const [
        AttachedTerminal(tabId: 'preview-tab-1', label: 'Terminal'),
      ],
      sessions: TerminalSessionsState(sessions: {'preview-tab-1': session}),
    );

    expect(contexts, hasLength(1));
    expect(contexts.single.text, '\$ flutter run\nNo devices found.');
    expect(contexts.single.detail, '/me/Musiky');
    expect(contexts.single.promptBlock, contains('[Terminal — /me/Musiky]'));
  });

  test('a terminal with nothing on it is left off the message', () {
    // A chip says something rode along. An empty block would make that a lie,
    // and spend prompt space saying nothing.
    final contexts = captureTerminalContexts(
      attached: const [
        AttachedTerminal(tabId: 'preview-tab-1', label: 'Terminal'),
      ],
      sessions: TerminalSessionsState(
        sessions: {
          'preview-tab-1': TerminalSession(
            id: 'preview-tab-1',
            workdir: '/me/Musiky',
          ),
        },
      ),
    );

    expect(contexts, isEmpty);
  });
}
