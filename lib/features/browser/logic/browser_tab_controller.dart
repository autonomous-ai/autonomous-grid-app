import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/external_launch.dart';
import 'browser_page.dart';
import 'browser_url.dart';

/// The page itself, as the controller needs to speak to it.
///
/// An interface rather than the engine's own object so `logic/` never imports
/// the web engine: the engine is a `presentation/` detail that already differs
/// per platform, and this is the whole surface the app drives it through.
abstract interface class BrowserPageHandle {
  Future<void> load(String url);
  Future<void> reload();
  Future<void> stop();
  Future<void> back();
  Future<void> forward();

  /// Run [source] in the page and hand back whatever it evaluated to.
  ///
  /// How the agent reads the page and acts on it — see
  /// `agent/browser_snapshot_script.dart`. Every script the app injects
  /// returns a JSON string, because what an engine marshals back differs by
  /// platform and a string is the one shape both return unchanged.
  Future<Object?> evaluate(String source);

  /// The visible page as PNG bytes, or null when the engine could not draw one.
  Future<Uint8List?> screenshot();
}

/// One browser tab: what it is showing, and the verbs that move it.
///
/// Per tab, keyed by the panel tab's id — two browser tabs are two pages with
/// their own history, the way two windows of a browser are two windows.
final browserTabProvider =
    NotifierProvider.family<BrowserTab, BrowserPageState, String>(
      BrowserTab.new,
    );

class BrowserTab extends Notifier<BrowserPageState> {
  BrowserTab(this.tabId);

  /// The panel tab this belongs to — the family argument, and what keeps one
  /// tab's history out of another's.
  final String tabId;

  /// The live page, once it exists. Not part of [state]: it is a handle onto
  /// something drawn by the platform, and state is a value.
  BrowserPageHandle? _page;

  /// The page, for the agent bridge — null before the engine has come up.
  ///
  /// The one reader outside this class, and it is deliberately a getter rather
  /// than a set of forwarding methods: the automation needs verbs this
  /// controller has no opinion about ([BrowserPageHandle.evaluate]), and
  /// growing a passthrough here for each of them would put the agent's whole
  /// vocabulary in the middle of the tab's own state.
  BrowserPageHandle? get page => _page;

  /// An address asked for before the page could take it — the user typing into
  /// a tab whose engine is still starting.
  String? _pending;

  @override
  BrowserPageState build() {
    // The page goes when the tab does. Nothing to kill — the widget disposes
    // the engine — but a handle onto a dead view answering later is worse than
    // no handle at all.
    ref.onDispose(detach);

    // The tab opens on the page chosen in Settings ▸ Browser, and on nothing at
    // all when that is blank — which is the default. Read rather than watched:
    // changing the setting decides where the *next* tab opens, and must not
    // pull a tab that is already somewhere back to a home page.
    final home = addressBarUrl(
      ref.read(chatPrefsProvider).browserHomePage,
      engine: _engine,
    );
    if (home == null) return const BrowserPageState();
    _pending = home;
    return BrowserPageState(url: home, load: const BrowserLoading(0));
  }

  /// Where a search goes, as chosen in Settings ▸ Browser.
  BrowserSearchEngine get _engine =>
      BrowserSearchEngine.byId(ref.read(chatPrefsProvider).browserSearchEngine);

  /// The engine is up and can be driven.
  void attach(BrowserPageHandle page) {
    _page = page;
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    page.load(pending);
  }

  void detach() {
    _page = null;
    _pending = null;
  }

  /// Go where the user typed.
  ///
  /// Three outcomes, and all three are answered: an address is opened, a
  /// `mailto:`-shaped one is handed to whichever app owns it, and anything else
  /// says so in the tab rather than searching for it behind the user's back.
  void submit(String typed) {
    final url = addressBarUrl(typed, engine: _engine);
    if (url != null) {
      _goTo(url);
      return;
    }
    if (classifyPageNavigation(typed) == PageNavigation.openInSystemBrowser) {
      openExternalUrl(typed.trim());
      return;
    }
    state = state.copyWith(
      load: BrowserFailed(
        message: "Grid can't open that kind of address.",
        url: typed.trim(),
      ),
    );
  }

  /// Reload, or stop when something is already on its way — one button, the way
  /// every browser does it.
  void reloadOrStop() {
    final page = _page;
    if (page == null) return;
    if (state.isBusy) {
      page.stop();
      return;
    }
    // A page that failed left an error behind it; reloading that shows the
    // error again. Going back to the address the user asked for is what they
    // meant by "try again".
    switch (state.load) {
      case BrowserFailed(:final url):
        _goTo(url);
      case BrowserIdle() || BrowserLoading() || BrowserReady():
        page.reload();
    }
  }

  void back() => _page?.back();

  void forward() => _page?.forward();

  void _goTo(String url) {
    state = state.copyWith(url: url, title: '', load: const BrowserLoading(0));
    final page = _page;
    if (page == null) {
      _pending = url;
      return;
    }
    page.load(url);
  }

  /// The page has started fetching something. Clears whatever was on screen —
  /// including a failure, which is what makes a retry that works look like one.
  void reportLoadStart(String url) => state = state.copyWith(
    url: url,
    title: '',
    load: const BrowserLoading(0),
  );

  /// [percent] is the engine's own 0–100.
  void reportProgress(int percent) {
    // Only while loading: a late progress event must not pull a finished page,
    // or a failed one, back under a progress bar.
    if (!state.isBusy) return;
    state = state.copyWith(load: BrowserLoading((percent / 100).clamp(0, 1)));
  }

  /// The page stopped fetching.
  void reportLoadStop(String url) {
    // A failure stands until something new is asked for. The engine reports the
    // error and *then* reports the error page it drew as loaded; taking that at
    // face value wipes the message the user needs a second before they read it.
    if (state.load is BrowserFailed) return;

    // The engine came to rest on the empty page while something else was on its
    // way. That navigation did not happen and nothing reported an error —
    // WebKit does exactly this for an address it refuses outright, a blocked
    // port being the one you meet by typing. Measured: `localhost:1` loads,
    // stops on `about:blank`, and raises nothing. A blank panel is the one
    // answer the user cannot act on, so this says so instead.
    final asked = state.url;
    if (url == blankPage && asked.isNotEmpty && asked != blankPage) {
      reportFailure(
        url: asked,
        message: "The page didn't open, and the browser didn't say why.",
      );
      return;
    }

    state = state.copyWith(url: url, load: const BrowserReady());
  }

  void reportTitle(String? title) {
    final named = title?.trim() ?? '';
    if (named.isEmpty) return;
    state = state.copyWith(title: named);
  }

  void reportHistory({required bool canGoBack, required bool canGoForward}) =>
      state = state.copyWith(canGoBack: canGoBack, canGoForward: canGoForward);

  void reportFailure({required String url, required String message}) =>
      state = state.copyWith(
        url: url,
        load: BrowserFailed(message: message, url: url),
      );
}
