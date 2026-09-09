import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/mcp/grid_browser_automation.dart';
import '../../../../infrastructure/state/agent_browser_choice.dart';
import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../../shared/panels/panel_tabs.dart';
import '../browser_page.dart';
import '../browser_tab_controller.dart';
import '../browser_url.dart';
import 'browser_action_scripts.dart';
import 'browser_snapshot_script.dart';

/// The Browser tab the agent is working in.
///
/// One per app rather than one per chat, because there is one preview panel:
/// the tab the agent drives is a tab the user is looking at, and pretending
/// each chat has its own would put pages behind each other with no way to tell
/// which is which. Null until an agent opens one.
final agentBrowserTabProvider = NotifierProvider<AgentBrowserTab, String?>(
  AgentBrowserTab.new,
);

class AgentBrowserTab extends Notifier<String?> {
  @override
  String? build() => null;

  void use(String tabId) => state = tabId;
}

/// How long a page is given to arrive before the agent is told it hasn't.
///
/// Generous, because the agent is not a person waiting — but bounded, because a
/// tool call that never returns takes the whole turn down with it (§6).
const Duration kBrowserActionTimeout = Duration(seconds: 25);

/// Drives the Browser tab on an agent's behalf.
///
/// Everything acts on **one visible tab**, which is the design rather than a
/// limitation: the user watches what the assistant does, and can take the
/// keyboard off it at any point by clicking in the page.
class PanelBrowserAutomation implements GridBrowserAutomation {
  const PanelBrowserAutomation(this._ref);

  /// Riverpod's `Ref`, named with an underscore so the interface's own `ref`
  /// argument — the handle a snapshot gave an element — keeps that word.
  final Ref _ref;

  @override
  Future<GridBrowserAnswer> snapshot() => _onPage((page) async {
    final decoded = await _json(page, kBrowserSnapshotScript);
    if (decoded == null) return _unreadable;
    return GridBrowserAnswer(
      'Page: ${decoded['title']}\nURL: ${decoded['url']}\n\n'
      '${decoded['snapshot']}',
    );
  });

  @override
  Future<GridBrowserAnswer> read({required int maxChars}) =>
      _onPage((page) async {
        final decoded = await _json(page, kBrowserReadScript);
        if (decoded == null) return _unreadable;
        final text = '${decoded['text']}';
        final body = text.length <= maxChars
            ? text
            : '${text.substring(0, maxChars)}\n…(truncated)';
        return GridBrowserAnswer(
          text.isEmpty
              ? 'The page has no readable text yet. It may still be loading.'
              : '${decoded['title']}\n${decoded['url']}\n\n$body',
        );
      });

  @override
  Future<GridBrowserAnswer> navigate(String url) async {
    final target = addressBarUrl(url);
    if (target == null) {
      return GridBrowserAnswer.failed(
        'Not an address this tab can open: "$url". Pass an http or https URL.',
      );
    }
    // The one verb that opens a tab: every other one needs a page that already
    // exists, and an agent that silently conjured tabs to click in would be
    // acting somewhere the user was never shown.
    final id = _tabId() ?? _openTab();
    _ref.read(browserTabProvider(id).notifier).submit(target);
    return _settled(id, doing: 'Opened');
  }

  @override
  Future<GridBrowserAnswer> click(String ref) => _act(
    browserClickScript(ref),
    describe: (result) => 'Clicked ${result['what'] ?? ref}.',
  );

  @override
  Future<GridBrowserAnswer> type({
    required String ref,
    required String text,
    required bool submit,
  }) => _act(
    browserTypeScript(ref, text: text, submit: submit),
    describe: (_) => submit ? 'Typed and pressed Enter.' : 'Typed.',
  );

  @override
  Future<GridBrowserAnswer> back() {
    final id = _tabId();
    if (id == null) return Future.value(_noPage);
    final tab = _ref.read(browserTabProvider(id).notifier);
    if (!_ref.read(browserTabProvider(id)).canGoBack) {
      return Future.value(
        GridBrowserAnswer.failed('There is nothing to go back to.'),
      );
    }
    tab.back();
    return _settled(id, doing: 'Went back to');
  }

  @override
  Future<GridBrowserAnswer> screenshot() => _onPage((page) async {
    final png = await page.screenshot();
    if (png == null) {
      return GridBrowserAnswer.failed('The engine could not draw the page.');
    }
    return GridBrowserAnswer('A picture of the page.', png: png);
  });

  /// Run [script] against the page and report it, or say why it could not.
  Future<GridBrowserAnswer> _act(
    String script, {
    required String Function(Map<String, Object?> result) describe,
  }) => _onPage((page) async {
    final result = await _json(page, script);
    if (result == null) return _unreadable;
    if (result['ok'] != true) {
      return GridBrowserAnswer.failed('${result['error']}');
    }
    // A click or an Enter can start a navigation. Waiting for it here is what
    // stops the agent snapshotting the page it just left.
    final id = _tabId();
    final settled = id == null ? null : await _settleIfLoading(id);
    return GridBrowserAnswer(
      settled == null ? describe(result) : '${describe(result)} $settled',
    );
  });

  Future<GridBrowserAnswer> _onPage(
    Future<GridBrowserAnswer> Function(BrowserPageHandle page) body,
  ) async {
    final id = _tabId();
    if (id == null) return _noPage;
    final page = _ref.read(browserTabProvider(id).notifier).page;
    if (page == null) return _noPage;
    return body(page);
  }

  /// Every script the app injects returns a JSON string; null means the engine
  /// handed back something else, which is a bug in the script rather than
  /// anything the agent did.
  Future<Map<String, Object?>?> _json(
    BrowserPageHandle page,
    String script,
  ) async {
    final raw = await page.evaluate(script);
    if (raw is! String) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?> ? decoded : null;
  }

  /// The Browser tab the agent works in: the one it opened, else the first one
  /// on the strip, else none.
  String? _tabId() {
    final tabs = _ref.read(panelTabsProvider(PanelHost.preview)).tabs;
    final chosen = _ref.read(agentBrowserTabProvider);
    for (final tab in tabs) {
      if (tab.id == chosen && tab.feature == PanelFeature.browser) {
        return tab.id;
      }
    }
    for (final tab in tabs) {
      if (tab.feature == PanelFeature.browser) return tab.id;
    }
    return null;
  }

  String _openTab() {
    final id = _ref
        .read(panelTabsProvider(PanelHost.preview).notifier)
        .open(PanelFeature.browser);
    _ref.read(agentBrowserTabProvider.notifier).use(id);
    return id;
  }

  /// Wait for the page to stop moving, then say where it landed.
  Future<GridBrowserAnswer> _settled(String id, {required String doing}) async {
    final deadline = DateTime.now().add(kBrowserActionTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final state = _ref.read(browserTabProvider(id));
      switch (state.load) {
        case BrowserReady():
          return GridBrowserAnswer(
            '$doing ${state.url}. Call browser_snapshot to see what is on it.',
          );
        case BrowserFailed(:final message, :final url):
          return GridBrowserAnswer.failed("Couldn't open $url — $message");
        case BrowserIdle() || BrowserLoading():
          continue;
      }
    }
    return GridBrowserAnswer.failed(
      'The page was still loading after '
      '${kBrowserActionTimeout.inSeconds}s. Try browser_snapshot anyway — '
      'part of it may be there.',
    );
  }

  /// The same wait, but only when something actually started loading — a click
  /// that changed nothing must not cost the agent a timeout.
  Future<String?> _settleIfLoading(String id) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!_ref.read(browserTabProvider(id)).isBusy) return null;
    final answer = await _settled(id, doing: 'The page moved to');
    return answer.text;
  }

  static const _noPage = GridBrowserAnswer.failed(
    'No page is open. Call browser_navigate with a URL first.',
  );

  static const _unreadable = GridBrowserAnswer.failed(
    'The page did not answer. It may still be loading — try again.',
  );
}

/// The Browser tab an agent may drive, or null when the user has not said yes.
///
/// The policy lives here rather than at the app root: the root only wires this
/// into [gridBrowserAutomationProvider], and what "allowed" means belongs to
/// the feature that knows what a Browser tab is.
final panelBrowserAutomationProvider = Provider<GridBrowserAutomation?>((ref) {
  // Two conditions, and both are hard nos: this computer has to be able to
  // draw a page at all, and the user has to have picked this browser over the
  // other two. Null is what keeps the tools out of `tools/list` entirely.
  if (!availablePanelFeatures.contains(PanelFeature.browser)) return null;
  final choice = ref.watch(chatPrefsProvider.select((p) => p.agentBrowser));
  if (choice != AgentBrowserChoice.gridTab) return null;
  return PanelBrowserAutomation(ref);
});
