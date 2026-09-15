import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../agents/logic/agent_catalog.dart';
import '../../../agents/logic/agent_model_support.dart';
import '../../../network/logic/network_models_provider.dart';
import '../../../playground/logic/playground_models.dart';
import '../../../playground/logic/playground_request.dart';
import 'telegram_menus.dart';

/// What the grid serves, **waited for** rather than read as it stands.
///
/// [playgroundModelsProvider] is `autoDispose` over a request in flight, so the
/// value it hands back on the spot is the empty list it starts from — and with
/// nobody watching it (the window need not even be on the Chat tab for the bot
/// to answer) the answer lands in a provider that has already been thrown away,
/// so the next command asks again and gets the same nothing. That is what
/// `/model` was doing: offering one row, and the one row that isn't a model the
/// grid serves.
///
/// The listener is what keeps the chain alive across the wait. It is closed as
/// soon as the list is in hand, so the bot holds no poll open between commands
/// — asking is what `/model` means, and a stale list is worse than a late one.
Future<List<PlaygroundModelOption>> telegramGridModels(Ref ref) async {
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

/// The rows `/model` offers: the text models on [options] that [agent] can
/// actually answer with, the one in use ticked.
///
/// Pure, so what the menu leaves out is read here rather than counted on a
/// phone. An assistant is filtered by [agentSupportsModel] for the same reason
/// the composer filters it — a pair that can't talk fails as a turn that never
/// answers, several minutes after the row was tapped.
List<TelegramMenuItem> telegramModelItems({
  required List<PlaygroundModelOption> options,
  required AgentTool agent,
  required String current,
}) => [
  for (final option in options)
    if (option.modality == PlaygroundModality.text &&
        agentSupportsModel(agent, option.id))
      (
        label: '${option.label}${option.id == current ? ' ✓' : ''}',
        value: option.id,
      ),
];

/// The model on [items] that [typed] names, or null when none does.
///
/// Case-insensitive to read a name typed on a phone, but it answers with the
/// **served** id rather than what was typed: the relay matches model ids
/// exactly, so handing it `deepseek-v4` for `DeepSeek-V4` is a turn that comes
/// back "no providers available" over a grid that serves it.
String? telegramModelNamed(List<TelegramMenuItem> items, String typed) {
  final wanted = typed.trim().toLowerCase();
  if (wanted.isEmpty) return null;
  for (final item in items) {
    if (item.value.toLowerCase() == wanted) return item.value;
  }
  return null;
}
