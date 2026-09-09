import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/host_arch.dart';
import '../../../../shared/external_launch.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../logic/browser_tab_controller.dart';
import '../../logic/browser_url.dart';

/// The web page itself.
///
/// The one file in the feature that knows which engine draws it — WKWebView on
/// macOS, WebView2 on Windows, both reached through the same plugin. Everything
/// above it speaks [BrowserPageHandle] instead, so the day Linux gets an engine
/// only this file and [supportsEmbeddedWeb] change.
class BrowserPageView extends ConsumerStatefulWidget {
  const BrowserPageView({super.key, required this.tabId});

  final String tabId;

  @override
  ConsumerState<BrowserPageView> createState() => _BrowserPageViewState();
}

class _BrowserPageViewState extends ConsumerState<BrowserPageView> {
  BrowserTab get _tab => ref.read(browserTabProvider(widget.tabId).notifier);

  /// Ask the engine what it can go back to, and tell the controller.
  ///
  /// Pulled rather than pushed because neither engine announces it: the two
  /// booleans are only ever true or false *now*, so they are re-read at the
  /// moments history can have moved.
  Future<void> _syncHistory(InAppWebViewController page) async {
    final back = await page.canGoBack();
    final forward = await page.canGoForward();
    if (!mounted) return;
    _tab.reportHistory(canGoBack: back, canGoForward: forward);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return InAppWebView(
      initialSettings: InAppWebViewSettings(
        // Off would leave most of the web blank; this is a browser.
        javaScriptEnabled: true,
        // What routes a clicked link through [classifyPageNavigation] instead
        // of letting the page go wherever it names.
        useShouldOverrideUrlLoading: true,
        // Two-finger swipe for back/forward on a trackpad — the gesture a Mac
        // user already has in their hands.
        allowsBackForwardNavigationGestures: true,
        // Web Inspector, in a debug build only: a page that can be attached to
        // in a shipped app is one a hostile site can be debugged from.
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (page) => _tab.attach(_EnginePage(page)),
      onLoadStart: (page, url) => _tab.reportLoadStart(url?.toString() ?? ''),
      onProgressChanged: (page, progress) => _tab.reportProgress(progress),
      onLoadStop: (page, url) {
        _tab.reportLoadStop(url?.toString() ?? '');
        _syncHistory(page);
      },
      onTitleChanged: (page, title) => _tab.reportTitle(title),
      // Fires for pushState too — a single-page app moving without a load.
      onUpdateVisitedHistory: (page, url, isReload) => _syncHistory(page),
      onReceivedError: (page, request, error) {
        // Sub-resources fail on healthy pages all the time — a tracker blocked,
        // an image missing. Only the page the user asked for is a failure worth
        // taking over the tab for.
        if (request.isForMainFrame == false) return;
        _tab.reportFailure(
          url: request.url.toString(),
          message: error.description,
        );
      },
      shouldOverrideUrlLoading: (page, action) async {
        final url = action.request.url?.toString();
        if (action.isForMainFrame == false) {
          return NavigationActionPolicy.ALLOW;
        }
        final verdict = classifyPageNavigation(url);
        // A mail link, a Zoom link, an app's own scheme: the OS knows what
        // opens it and this tab does not.
        if (verdict == PageNavigation.openInSystemBrowser && url != null) {
          await openExternalUrl(url);
        }
        return verdict == PageNavigation.allow
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      // A link asking for a window of its own — `target="_blank"`. There are no
      // windows here, so it opens where the user is looking rather than
      // silently doing nothing, which is what returning false would do.
      onCreateWindow: (page, request) async {
        final url = request.request.url?.toString();
        if (url == null) return false;
        _tab.submit(url);
        return false;
      },
      // A certificate the system doesn't trust is left to the plugin's own
      // default, which is to refuse the page. There is deliberately no
      // "continue anyway" here: this tab has no way to explain what the user
      // would be agreeing to.
    );
  }
}

/// The engine, behind the five verbs the controller drives it with.
class _EnginePage implements BrowserPageHandle {
  const _EnginePage(this.page);

  final InAppWebViewController page;

  @override
  Future<void> load(String url) =>
      page.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

  @override
  Future<void> reload() => page.reload();

  @override
  Future<void> stop() => page.stopLoading();

  @override
  Future<void> back() => page.goBack();

  @override
  Future<void> forward() => page.goForward();
}
