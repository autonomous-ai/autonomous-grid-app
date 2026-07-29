import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/connector_token.dart';
import 'connector_link_controller.dart';
import 'connector_token_store.dart';

/// Keeps stored connector tokens alive while the app runs.
///
/// Access tokens are short — Google issues an hour, and the agent stops working
/// the moment one lapses. The gateway will mint a replacement from the refresh
/// token, but only if somebody asks; nothing on this machine asks on its own.
/// Hermes won't: its own OAuth machinery refreshes using a `client_id` and
/// secret that live at the gateway and are never on this computer, so left to
/// itself it would fail the refresh and fall back to opening a browser — the
/// one outcome this whole flow exists to avoid.
///
/// **Why a deadline and not a poll.** A fixed interval is either too slow (a
/// token dies between ticks) or wasteful (most ticks have nothing to do). Each
/// token already says when it expires, so this sleeps until the earliest of
/// them is nearly due, refreshes what's ripe, then re-arms from whatever the
/// new set says. A quiet machine wakes roughly once an hour; an idle one with
/// no connectors never wakes at all.
///
/// **What it deliberately does not do.** Nothing happens while the app is
/// closed. That is survivable rather than ideal: refresh tokens outlive access
/// tokens by months, so the sweep on the next launch renews everything that
/// lapsed overnight. It matters less than it sounds, too — Hermes is spawned by
/// this app, so a connector that goes stale while the app is shut is one no
/// agent was using anyway.
class ConnectorRefreshService {
  ConnectorRefreshService(this._ref);

  final Ref _ref;

  Timer? _timer;

  /// Guards against two sweeps overlapping — a slow gateway plus a short timer
  /// would otherwise have the second sweep read tokens the first is rewriting.
  bool _sweeping = false;

  /// How early to replace a token. Long enough that a request already in flight
  /// when the sweep starts still lands with a valid credential.
  static const Duration _headStart = Duration(minutes: 5);

  /// The soonest the service will re-arm. A token that arrives already expiring
  /// would otherwise schedule a wake-up for right now, and every failed refresh
  /// would spin.
  static const Duration _minDelay = Duration(minutes: 1);

  /// The longest it will sleep. Not a correctness bound — the deadline maths
  /// covers that — but a way back to a sane schedule after the machine wakes
  /// from a suspend with a timer that measured the wrong stretch of time.
  static const Duration _maxDelay = Duration(hours: 1);

  /// Sweep once, then keep the schedule going. Safe to call more than once.
  Future<void> start() async {
    await _sweep();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// Refresh whatever is due, then arm the next wake-up.
  Future<void> _sweep() async {
    if (_sweeping) return;
    _sweeping = true;
    try {
      final tokens = await _readTokens();
      for (final token in tokens.values) {
        if (!token.needsRefresh()) continue;
        // One failure doesn't stop the sweep: connectors are independent, and a
        // provider having a bad minute shouldn't strand the others. The
        // controller already handles the terminal case — a 401 means the
        // credential is gone for good, and it clears it locally rather than
        // retrying forever.
        await _ref
            .read(connectorLinkControllerProvider.notifier)
            .refresh(token.connector);
      }
    } on Object {
      // A sweep that throws must still re-arm, or one bad read ends refreshing
      // for the rest of the session.
    } finally {
      _sweeping = false;
      await _arm();
    }
  }

  /// Sleep until the earliest token needs attention.
  Future<void> _arm() async {
    _timer?.cancel();
    _timer = null;

    final tokens = await _readTokens();
    // The same test `needsRefresh` applies, minus the clock: a token this will
    // never renew must not set an alarm, and one it *would* renew must set one
    // even without an `mcp_entry`. Those are not the same set — a connector the
    // gateway has no MCP server for still has a real, expiring credential — and
    // an earlier version of this method checked only the entry, which left
    // exactly those tokens with no deadline watching them.
    final deadlines = [
      for (final token in tokens.values)
        if (token.expiresAt != null && token.canBeRefreshed) token.expiresAt!,
    ];
    // Nothing refreshable: no timer at all. The service re-arms on its own when
    // a sign-in lands, because that path calls [start] again.
    if (deadlines.isEmpty) return;

    deadlines.sort();
    final due = deadlines.first.subtract(_headStart);
    final wait = due.difference(DateTime.now());
    final delay = wait < _minDelay
        ? _minDelay
        : (wait > _maxDelay ? _maxDelay : wait);

    _timer = Timer(delay, _sweep);
  }

  Future<Map<String, ConnectorToken>> _readTokens() async {
    try {
      return await _ref.read(connectorTokenStoreProvider).read();
    } on Object {
      return const {};
    }
  }
}

/// The running refresh service.
///
/// Kept alive for the life of the app: reading it once at startup is what
/// starts the schedule, and nothing else needs to hold a reference.
final connectorRefreshServiceProvider = Provider<ConnectorRefreshService>((
  ref,
) {
  final service = ConnectorRefreshService(ref);
  ref.onDispose(service.dispose);
  return service;
});
