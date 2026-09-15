/// The picks the composer offers, as the computer worked them out.
///
/// Nothing here decides anything. Which agent can answer with which model, what
/// a mode is called, which grid serves what — every one of those is a rule that
/// lives on the computer and has changed as the app changed. The phone asks,
/// draws the answer, and sends back an id.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_chats.dart';
import 'phone_link_controller.dart';
import 'relay_phone_client.dart';

/// One thing that can be picked.
///
/// [enabled] and [why] come from the computer rather than being worked out
/// here: an option drawn as available that then refuses is worse than one drawn
/// greyed out with the reason under it (§5).
typedef PickOption = ({String id, String label, bool enabled, String why});

/// One picker: what is chosen now, and what else there is.
typedef Picker = ({String selected, List<PickOption> options});

/// Everything the composer's three pills show for one chat.
typedef ChatOptions = ({Picker model, Picker agent, Picker approval});

/// What can be picked for a chat.
///
/// Keyed by chat because the answers are per chat — the agent that can answer
/// depends on the model that chat is on.
final chatOptionsProvider = FutureProvider.family<ChatOptions, String>((
  ref,
  chatId,
) async {
  final result = await ref.watch(phoneLinkProvider.notifier).call(
    'chats.options',
    {'id': chatId},
  );
  return (
    model: _picker(result['model']),
    agent: _picker(result['agent']),
    approval: _picker(result['approval']),
  );
}, retry: null);

/// Changes one thing about a chat, and re-reads what that did.
///
/// Takes a [WidgetRef] because a pick is something a person does: the callers
/// are the composer's pills, and there is no provider whose own state this
/// belongs to — it changes a chat on another computer.
///
/// Returns null when it worked, or the computer's own sentence when it did not
/// — it is the side that knows why, and it phrases these for a person.
Future<String?> pickChatOption(
  WidgetRef ref, {
  required String chatId,
  required String field,
  required String value,
}) async {
  try {
    await ref.read(phoneLinkProvider.notifier).call('chats.set', {
      'id': chatId,
      'field': field,
      'value': value,
    });
  } on RelayPhoneFailure catch (failure) {
    return failure.message;
  }
  // Both, and in this order. Changing the model changes which agents can
  // answer, so a picker left showing the old answer would offer a pair the
  // computer has just started refusing.
  ref.invalidate(chatOptionsProvider(chatId));
  ref.invalidate(chatListProvider);
  return null;
}

/// Starts a chat carrying its first message, and returns the new chat's id.
///
/// Throws [RelayPhoneFailure] with a sentence the computer wrote — an empty
/// grid or a model that is not running are its facts to report, not ours.
Future<String> startChat(
  WidgetRef ref, {
  required String text,
  String? projectId,
}) async {
  final result = await ref.read(phoneLinkProvider.notifier).call(
    'chats.create',
    {'text': text, 'projectId': ?projectId},
  );
  final id = result['id'];
  if (id is! String || id.isEmpty) {
    throw const RelayPhoneFailure('The chat could not be started.');
  }
  ref.invalidate(chatListProvider);
  return id;
}

Picker _picker(Object? value) {
  if (value is! Map) return (selected: '', options: const []);
  return (
    selected: '${value['selected'] ?? ''}',
    options: [
      for (final option
          in value['options'] is List ? value['options']! as List : const [])
        if (option is Map)
          (
            id: '${option['id'] ?? ''}',
            label: '${option['label'] ?? ''}',
            // Absent reads as pickable: an older computer that does not send
            // the field is not one that means "no".
            enabled: option['enabled'] != false,
            why: '${option['why'] ?? ''}',
          ),
    ],
  );
}
