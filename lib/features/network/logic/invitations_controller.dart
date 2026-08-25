import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/managed_network_client.dart';
import '../../../infrastructure/api/models/grid_invitation.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';

/// `GET /v1/grid/me/memberships`, behind a provider so tests can swap in a fake.
typedef ListInvitationsFn =
    Future<(List<GridInvitation>?, String?)> Function({
      required String apiUrl,
      required String sessionToken,
    });

/// `POST /v1/grid/me/memberships/seen`.
typedef MarkInvitationsSeenFn =
    Future<(int?, String?)> Function({
      required String apiUrl,
      required String sessionToken,
      required List<String> networkIds,
    });

final listInvitationsFnProvider = Provider<ListInvitationsFn>(
  (ref) => ManagedNetworkClient.listInvitations,
);

final markInvitationsSeenFnProvider = Provider<MarkInvitationsSeenFn>(
  (ref) => ManagedNetworkClient.markInvitationsSeen,
);

/// How often unseen invitations are refetched.
///
/// A minute, matching [gridOverviewRefreshIntervalProvider], and for the same
/// reason: this is a badge count, not a live figure. Nobody is waiting on the
/// second an invitation arrives, and a faster tick would put a request on the
/// wire every few seconds for a number that is usually zero. Overridable so
/// tests never wait on a real clock.
final invitationsPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 60),
);

sealed class InvitationsState {
  const InvitationsState();

  /// What the badge counts. Zero for every state but a loaded one, so the icon
  /// is quiet while loading and quiet after a failure — a count nobody can act
  /// on is worse than none.
  int get unseenCount => switch (this) {
    InvitationsReady(:final items) => items.length,
    _ => 0,
  };
}

/// The first fetch, before there is anything to show.
class InvitationsLoading extends InvitationsState {
  const InvitationsLoading();
}

class InvitationsReady extends InvitationsState {
  const InvitationsReady(this.items, {this.staleError});

  final List<GridInvitation> items;

  /// Set when a REFRESH failed while these items were already on screen. The
  /// list stays; this is the footnote saying it may be out of date.
  ///
  /// A poll that fails must not blank a good list — on a flaky connection the
  /// badge would flicker between a number and nothing every minute, which reads
  /// as invitations appearing and vanishing.
  final String? staleError;
}

/// The first fetch failed, so there is nothing to show at all.
class InvitationsFailed extends InvitationsState {
  const InvitationsFailed(this.message);

  final String message;
}

/// Unseen invitations, kept fresh on a timer, with the two ways to dismiss them.
///
/// Only runs while signed in: the session token comes from
/// [sessionProvider], and losing it stops the timer rather than polling an
/// endpoint that can only answer 401.
class InvitationsController extends Notifier<InvitationsState> {
  Timer? _timer;

  /// Guards against two fetches overlapping — a slow answer plus a 60s tick
  /// would otherwise stack requests, and the later reply could land first and
  /// overwrite the newer list with an older one.
  bool _fetching = false;

  @override
  InvitationsState build() {
    final token = ref.watch(sessionProvider).sessionToken;
    ref.onDispose(() => _timer?.cancel());
    _timer?.cancel();
    if (token == null || token.isEmpty) return const InvitationsReady([]);

    final interval = ref.read(invitationsPollIntervalProvider);
    _timer = Timer.periodic(interval, (_) => refresh());
    // Not awaited, and not started from inside `build` synchronously either:
    // a Notifier's build must return a state, and a state that arrives later is
    // what `refresh` is for.
    scheduleMicrotask(refresh);
    return const InvitationsLoading();
  }

  /// Refetches. Safe to call at any time; overlapping calls are dropped.
  Future<void> refresh() async {
    if (_fetching) return;
    final token = ref.read(sessionProvider).sessionToken;
    if (token == null || token.isEmpty) return;
    _fetching = true;
    try {
      final (items, error) = await ref.read(listInvitationsFnProvider)(
        apiUrl: ref.read(gridApiUrlProvider),
        sessionToken: token,
      );
      if (items != null) {
        state = InvitationsReady(List.unmodifiable(items));
        return;
      }
      final message = error ?? "Couldn't read your invitations.";
      state = switch (state) {
        InvitationsReady(:final items) => InvitationsReady(
          items,
          staleError: message,
        ),
        _ => InvitationsFailed(message),
      };
    } finally {
      _fetching = false;
    }
  }

  /// Acknowledges [networkIds], and drops them from the list without waiting for
  /// the next poll.
  ///
  /// The rows are removed locally on success rather than by refetching: the
  /// person just dismissed them, and having them sit there for up to a minute
  /// reads as the tap not registering. Returns the failure message, or null.
  Future<String?> markSeen(List<String> networkIds) async {
    if (networkIds.isEmpty) return null;
    final token = ref.read(sessionProvider).sessionToken;
    if (token == null || token.isEmpty) {
      return 'Sign in before marking invitations as read.';
    }
    final (_, error) = await ref.read(markInvitationsSeenFnProvider)(
      apiUrl: ref.read(gridApiUrlProvider),
      sessionToken: token,
      networkIds: networkIds,
    );
    if (error != null) return error;
    final dismissed = networkIds.toSet();
    final current = state;
    if (current is InvitationsReady) {
      state = InvitationsReady(
        List.unmodifiable(
          current.items.where((i) => !dismissed.contains(i.networkId)),
        ),
      );
    }
    return null;
  }

  /// "Mark all as read" — sends back exactly the ids currently on screen.
  ///
  /// Not a "dismiss everything" call, because the server has no such thing: an
  /// invitation arriving between the last poll and this tap is not in this list,
  /// so it survives instead of being dismissed by somebody who never saw it.
  Future<String?> markAllSeen() async {
    final current = state;
    if (current is! InvitationsReady) return null;
    return markSeen([for (final item in current.items) item.networkId]);
  }
}

final invitationsControllerProvider =
    NotifierProvider<InvitationsController, InvitationsState>(
      InvitationsController.new,
    );
