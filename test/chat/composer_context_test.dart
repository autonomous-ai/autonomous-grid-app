import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/composer_context.dart';
import 'package:grid_app/shared/panels/panel_tabs.dart';
import 'package:grid_app/features/terminal/logic/terminal_session.dart';
import 'package:grid_app/features/terminal/logic/terminal_sessions_controller.dart';

void main() {
  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        // No real shell: what's under test is which terminals a message carries,
        // and spawning a login shell per case would make it slow and
        // machine-dependent for nothing.
        shellStarterProvider.overrideWithValue((session, onError) {}),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a message carries no terminal until one is put on it', () {
    // The point of the feature, stated as a test: opening a terminal to look
    // something up must not quote a screenful of it at the model.
    final c = container();
    c
        .read(panelTabsProvider(PanelHost.preview).notifier)
        .open(PanelFeature.terminal);

    expect(c.read(attachedTerminalsProvider), isEmpty);
  });

  test('dropping a terminal on the conversation puts it on the message', () {
    final c = container();

    c
        .read(attachedTerminalsProvider.notifier)
        .attach(tabId: 'preview-tab-1', label: 'Terminal');

    final attached = c.read(attachedTerminalsProvider);
    expect(attached, hasLength(1));
    expect(attached.single.tabId, 'preview-tab-1');
    expect(attached.single.label, 'Terminal');
  });

  test('dropping the same terminal twice still sends it once', () {
    // Two chips for one shell would send the same screen twice and give the
    // user two ✕ to press to undo one gesture.
    final c = container();
    final notifier = c.read(attachedTerminalsProvider.notifier);

    notifier.attach(tabId: 'preview-tab-1', label: 'Terminal');
    notifier.attach(tabId: 'preview-tab-1', label: 'Terminal');

    expect(c.read(attachedTerminalsProvider), hasLength(1));
  });

  test('✕ takes the terminal back off', () {
    final c = container();
    final notifier = c.read(attachedTerminalsProvider.notifier);
    notifier.attach(tabId: 'preview-tab-1', label: 'Terminal');
    notifier.attach(tabId: 'bottom-tab-1', label: 'Terminal 2');

    notifier.remove('preview-tab-1');

    final labels = [for (final t in c.read(attachedTerminalsProvider)) t.label];
    expect(labels, ['Terminal 2']);
  });

  test('closing a terminal tab takes its chip with it', () {
    // Otherwise the chip stands there promising a screen that no longer exists,
    // and Send quietly carries nothing.
    final c = container();
    final id = c
        .read(panelTabsProvider(PanelHost.bottom).notifier)
        .open(PanelFeature.terminal);
    c
        .read(attachedTerminalsProvider.notifier)
        .attach(tabId: id, label: 'Terminal');

    c.read(panelTabsProvider(PanelHost.bottom).notifier).close(id);

    expect(c.read(attachedTerminalsProvider), isEmpty);
  });

  test('a terminal is put on one message, not on the conversation', () {
    // What Send does. Without it, one drop would quote that terminal into every
    // message after it.
    final c = container();
    c
        .read(attachedTerminalsProvider.notifier)
        .attach(tabId: 'preview-tab-1', label: 'Terminal');

    c.read(attachedTerminalsProvider.notifier).clear();

    expect(c.read(attachedTerminalsProvider), isEmpty);
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
