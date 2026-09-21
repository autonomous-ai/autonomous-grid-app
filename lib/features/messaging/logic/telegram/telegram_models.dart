import '../../../agents/logic/agent_catalog.dart';
import '../../../agents/logic/agent_model_support.dart';
import '../../../playground/logic/playground_models.dart';
import '../../../playground/logic/playground_request.dart';
import 'telegram_menus.dart';

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
