import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What one browser tool call comes back with.
///
/// One type for every verb, because the MCP server only ever does two things
/// with an answer: put it in front of the model, and say whether it was a
/// refusal. [png] is the exception a picture earns.
class GridBrowserAnswer {
  const GridBrowserAnswer(this.text, {this.failed = false, this.png});

  /// A refusal the agent can act on — no page open, a ref that has gone stale.
  const GridBrowserAnswer.failed(this.text) : failed = true, png = null;

  /// What the agent reads.
  final String text;

  /// True when the call did not do what was asked. Surfaced as MCP's `isError`
  /// so the model reports it rather than carrying on as though it worked.
  final bool failed;

  /// A PNG of the page, for `browser_screenshot` alone.
  final Uint8List? png;
}

/// The Browser tab, as an agent drives it.
///
/// Implemented by the browser feature and reached through
/// [gridBrowserAutomationProvider] — the server lives in `infrastructure/` and
/// must not know a panel or a widget exists.
///
/// Every verb acts on **the tab the user can see**, with the user's own
/// session: their cookies, their logins. That is the whole point and the whole
/// risk, which is why the provider below is null unless the user has said yes.
abstract interface class GridBrowserAutomation {
  /// The page as a tree of roles, names and refs.
  Future<GridBrowserAnswer> snapshot();

  /// The page's readable text, cut to [maxChars].
  Future<GridBrowserAnswer> read({required int maxChars});

  /// Go to [url], opening a Browser tab if none is open.
  Future<GridBrowserAnswer> navigate(String url);

  /// Click the element a snapshot called [ref].
  Future<GridBrowserAnswer> click(String ref);

  /// Put [text] into the input a snapshot called [ref], optionally pressing
  /// Enter afterwards.
  Future<GridBrowserAnswer> type({
    required String ref,
    required String text,
    required bool submit,
  });

  /// Back, in the tab's own history.
  Future<GridBrowserAnswer> back();

  /// A picture of what is on screen.
  Future<GridBrowserAnswer> screenshot();
}

/// The Browser tab an agent may drive, or **null** — which is both "this
/// computer has no such tab" and "the user has not allowed it".
///
/// Null by default and overridden at the app root the way `appLogProvider` is:
/// the tab is a feature and infrastructure never reaches into one. Null is also
/// the single switch behind the whole surface — with it, the browser tools are
/// not offered in `tools/list` and are refused in `tools/call`, so an agent
/// that was told about them in an earlier session cannot use them now.
final gridBrowserAutomationProvider = Provider<GridBrowserAutomation?>(
  (_) => null,
);
