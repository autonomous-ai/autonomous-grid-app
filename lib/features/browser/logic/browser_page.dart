import 'package:flutter/foundation.dart';

/// How far the page in a browser tab has got.
///
/// Sealed rather than a `loading` flag beside an `error` string: a tab is in
/// exactly one of these at a time, and the pair of booleans that replaced it
/// could say "loading and failed" — which is how a spinner ends up turning over
/// an error message nobody can dismiss.
sealed class BrowserLoad {
  const BrowserLoad();
}

/// A tab that has been opened and not yet pointed anywhere.
final class BrowserIdle extends BrowserLoad {
  const BrowserIdle();
}

/// A page on its way in.
final class BrowserLoading extends BrowserLoad {
  const BrowserLoading(this.progress);

  /// 0 → 1. Straight from the engine, and it is a *hint*: a page can sit at
  /// 0.9 for a while, so this draws a bar, never a percentage.
  final double progress;
}

/// A page that arrived.
final class BrowserReady extends BrowserLoad {
  const BrowserReady();
}

/// A page that did not.
final class BrowserFailed extends BrowserLoad {
  const BrowserFailed({required this.message, required this.url});

  /// What went wrong, in the engine's own words. Shown under a sentence of the
  /// app's own, because "The Internet connection appears to be offline" is
  /// worth reading and `NSURLErrorDomain -1009` is not.
  final String message;

  /// The address that failed, so retrying goes back to what the user asked for
  /// rather than reloading the error page standing in for it.
  final String url;
}

/// What one browser tab is showing.
@immutable
class BrowserPageState {
  const BrowserPageState({
    this.url = '',
    this.title = '',
    this.canGoBack = false,
    this.canGoForward = false,
    this.load = const BrowserIdle(),
  });

  /// The address of the page on screen — empty in a tab nothing has been asked
  /// of yet.
  final String url;

  /// The page's own title. Empty until it has one, which is most of the time a
  /// page is loading.
  final String title;

  final bool canGoBack;
  final bool canGoForward;

  final BrowserLoad load;

  /// True while something is on its way — what the reload button reads to
  /// become a stop button.
  bool get isBusy => load is BrowserLoading;

  BrowserPageState copyWith({
    String? url,
    String? title,
    bool? canGoBack,
    bool? canGoForward,
    BrowserLoad? load,
  }) => BrowserPageState(
    url: url ?? this.url,
    title: title ?? this.title,
    canGoBack: canGoBack ?? this.canGoBack,
    canGoForward: canGoForward ?? this.canGoForward,
    load: load ?? this.load,
  );
}
