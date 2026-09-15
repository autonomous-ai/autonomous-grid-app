/// Asking the open grid what it serves, from outside the window.
///
/// Lives here rather than beside the Telegram bot that first needed it: the
/// paired phone's model picker needs exactly the same thing, and the trap it
/// exists to avoid caught both of them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../network/logic/network_models_provider.dart';
import 'playground_models.dart';

/// What the grid serves, **waited for** rather than read as it stands.
///
/// [playgroundModelsProvider] is `autoDispose` over a request in flight, so the
/// value it hands back on the spot is the empty list it starts from — and with
/// nobody watching it (the window need not even be on the Chat tab for the bot
/// to answer) the answer lands in a provider that has already been thrown away,
/// so the next command asks again and gets the same nothing. That is what
/// `/model` was doing, and what the phone's model picker did after it: offering one row, and the one row that isn't a model the
/// grid serves.
///
/// The listener is what keeps the chain alive across the wait. It is closed as
/// soon as the list is in hand, so no caller holds a poll open between asks
/// — asking is the point, and a stale list is worse than a late one, and a stale list is worse than a late one.
Future<List<PlaygroundModelOption>> gridServedModels(Ref ref) async {
  final alive = ref.listen(playgroundModelsProvider, (_, _) {});
  var served = const <PlaygroundModelOption>[];
  try {
    await ref.read(networkModelsProvider.future);
    served = ref.read(playgroundModelsProvider);
  } on Object {
    // A grid that can't say what it serves offers nothing — never a guess.
  }
  alive.close();
  return served;
}
