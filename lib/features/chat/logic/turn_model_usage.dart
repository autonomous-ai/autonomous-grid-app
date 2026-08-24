import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/relay_api_client.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import 'turn_model_share.dart';

/// How often an open turn re-asks the grid what has served it so far.
///
/// Slow on purpose: this is a caption, not a progress bar. Five seconds is
/// quick enough that a minute-long task shows its models changing, and rare
/// enough that a turn making a request a second doesn't spend its bandwidth on
/// telling the user about itself.
const Duration kUsagePollInterval = Duration(seconds: 5);

/// Which models are serving each open turn, keyed by conversation id.
///
/// The grid is the only party that knows. The agent CLI makes the relay calls,
/// so the app never sees their responses — and the agent only knows the name it
/// was *given* (`auto`, or a tier alias), never the one the router picked.
///
/// Correlation is by TURN ID: the app mints one id per user input and injects
/// it into the agent CLI as `X-Request-Id`, so every relay call of a turn
/// carries the same value. `GET /usage/turn/{id}` counts exactly that turn's
/// calls — two turns running at once on the same grid never blend into each
/// other (unlike the old time-window caption the relay served before).
class TurnModelUsage extends Notifier<Map<String, List<ModelShare>>> {
  final _timers = <String, Timer>{};
  final _turns = <String, String>{};

  @override
  Map<String, List<ModelShare>> build() {
    ref.onDispose(() {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
    });
    return const {};
  }

  /// Start watching [chat]'s turn, stamped with this turn's [turnId] so the
  /// relay can count exactly what serves it. Clears whatever the previous turn
  /// left, so a new question never inherits the last one's models.
  void begin(String chat, NetworkCredential network, String turnId) {
    stop(chat);
    _turns[chat] = turnId;
    state = {...state}..remove(chat);
    _timers[chat] = Timer.periodic(
      kUsagePollInterval,
      (_) => _poll(chat, network),
    );
    unawaited(_poll(chat, network));
  }

  /// Stop watching, take one last reading, and return it.
  ///
  /// The last poll matters: a turn that ends four seconds after the previous one
  /// would otherwise be recorded without its final requests.
  Future<List<ModelShare>> end(String chat, NetworkCredential network) async {
    final turnId = _turns[chat];
    stop(chat);
    if (turnId == null) return const [];
    // Read the fallback BEFORE the await: `state` is unreachable once the
    // provider is disposed, and a chat closed while this last read is in flight
    // disposes it. Reading it after the gap threw
    // "Cannot use the Ref ... after it has been disposed" and failed the turn
    // that had already answered.
    final polled = state[chat] ?? const <ModelShare>[];
    final shares = await _fetch(network, turnId);
    return shares ?? polled;
  }

  /// Drop the timer and the turn without reading anything — used when a chat
  /// is deleted mid-turn, and by [begin] before it re-arms.
  void stop(String chat) {
    _timers.remove(chat)?.cancel();
    _turns.remove(chat);
  }

  Future<void> _poll(String chat, NetworkCredential network) async {
    final turnId = _turns[chat];
    if (turnId == null) return;
    final shares = await _fetch(network, turnId);
    // A failed read leaves the last good answer standing. A caption that blinks
    // to nothing every time a poll times out is worse than one that is stale.
    // `ref.mounted` guards the async gap: the chat may have been closed, and the
    // provider disposed, while this poll was on the wire.
    if (shares == null || !ref.mounted || !_timers.containsKey(chat)) return;
    state = {...state, chat: shares};
  }

  /// One read, or null when the grid could not answer.
  ///
  /// Null covers the case that will be the common one for a while: a grid whose
  /// master predates `/relay/v1/usage` answers **404**, and that has to read as
  /// "no data yet", never as an error the user is shown.
  Future<List<ModelShare>?> _fetch(
    NetworkCredential network,
    String turnId,
  ) async {
    if (!ref.mounted) return null;
    try {
      final result = await ref
          .read(relayApiClientProvider)
          .usageTurn(
            baseUrl: network.relayBaseUrl,
            apiKey: network.relayApiKey,
            turnId: turnId,
          );
      return result;
    } on Object {
      return null;
    }
  }
}

final turnModelUsageProvider =
    NotifierProvider<TurnModelUsage, Map<String, List<ModelShare>>>(
      TurnModelUsage.new,
    );

/// What is serving [chat]'s open turn right now — empty until the first poll
/// lands, or on a grid that cannot answer.
final openTurnModelsProvider = Provider.autoDispose
    .family<List<ModelShare>, String>(
      (ref, chat) => ref.watch(turnModelUsageProvider)[chat] ?? const [],
    );
