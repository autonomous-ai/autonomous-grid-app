import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The three ways this computer can put intelligence on a grid.
///
/// One axis, three values, and every state of the page is one of them plus
/// "already sharing". They were three stacked disclosures before: rows you
/// opened one at a time, each unfolding a form under the two you hadn't read.
/// That shape asks the reader to compare options by opening and closing them.
/// As a route picked on the left and configured on the right, all three stay
/// visible while one is being set up.
enum ShareRoute { local, key, server }

/// Which route the page opens on, given what this machine can actually do.
///
/// Never a route the machine can't take: opening on "run a model here" for a
/// computer with no built-in engine support puts a form in front of someone
/// whose first move has to be somewhere else. Local leads when it is possible
/// because it is the only route that costs nothing and sends nothing — an
/// answer the other two can't give.
///
/// Pure, so the ordering is a tested rule rather than a chain of `??` in a
/// `build()`.
ShareRoute defaultShareRoute({
  required bool canRunLocal,
  required bool serverFound,
  required bool hasKeyProvider,
}) {
  if (canRunLocal) return ShareRoute.local;
  // Something is already running on this machine — one press from shared, and
  // no download.
  if (serverFound) return ShareRoute.server;
  if (hasKeyProvider) return ShareRoute.key;
  // The endpoint form takes a typed address, so it is the one route that is
  // always available even when nothing was detected and no provider is
  // whitelisted.
  return ShareRoute.server;
}

/// The route the reader picked, or null while the page still follows
/// [defaultShareRoute].
///
/// Null rather than a seeded value on purpose: detection lands a frame or two
/// after the page opens, and a controller that had to be *told* the default
/// would need a side effect in `build()` to do it (§2).
final shareRouteProvider = NotifierProvider<ShareRouteController, ShareRoute?>(
  ShareRouteController.new,
);

/// Holds the reader's choice of route for as long as the app is open.
class ShareRouteController extends Notifier<ShareRoute?> {
  @override
  ShareRoute? build() => null;

  void pick(ShareRoute route) => state = route;
}
