/// The chat history and the projects, as the phone sees them.
///
/// Everything here goes through [PhoneLinkController.call], so there is one
/// connection to the computer and one place that owns it. The desktop decides
/// what these answers contain — the phone is never sent a project's path or a
/// message's attachments — so nothing here reassembles a chat, it renders what
/// arrived.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_link_controller.dart';

/// One conversation in the list — its header, never its messages.
typedef ChatRow = ({
  String id,
  String title,
  String model,
  String agent,
  String projectId,
  String updatedAt,
  bool archived,
});

/// One project the computer has.
typedef ProjectRow = ({String id, String name, String model, String agent});

/// One turn of a conversation.
///
/// [index] is the turn's place in the whole chat, which is how a picture on it
/// is asked for. [media] describes attachments without carrying them: a photo
/// is measured in megabytes and the channel cannot frame one.
typedef ChatLine = ({
  String role,
  String text,
  int index,
  List<ChatMediaRef> media,
});

/// A picture attached to a turn, named but not yet fetched.
typedef ChatMediaRef = ({String kind, String name});

/// A page of one conversation, newest last.
///
/// [busy] is whether the computer is still writing an answer in this chat. It
/// is what tells the phone to keep looking after it sends: a turn takes tens of
/// seconds, far longer than a request can be held open, so the answer arrives
/// by asking again rather than by waiting.
typedef ChatTranscript = ({
  String id,
  List<ChatLine> lines,
  int total,
  int offset,
  bool busy,
});

/// Which page of a conversation to ask for.
///
/// [offset] counts turns from the *start*, so a smaller one walks backwards
/// into the history; null asks for the newest page, which is what a chat opens
/// on. A record rather than two provider families: the pair is one request, and
/// two families would let a screen ask for a page of one chat at the offset of
/// another.
typedef TranscriptRequest = ({String id, int? offset});

/// Every conversation on the computer, newest activity first — **archived ones
/// included**.
///
/// They used to be dropped here, which quietly meant the phone had no archive
/// at all: not "hidden by default" but *absent*, with no screen able to show
/// them and no way to put one away. Filtering is the screen's job, and each
/// screen says which half it wants ([liveChats], [archivedChats]).
///
/// `retry: null` because Riverpod 3 otherwise retries a failed provider ten
/// times — and a failure here is usually the channel being down, so retrying
/// is ten more requests into a socket that is not answering.
final chatListProvider = FutureProvider<List<ChatRow>>((ref) async {
  final result = await ref.watch(phoneLinkProvider.notifier).call('chats.list');
  final rows = result['chats'];
  if (rows is! List) return const [];
  return [
    for (final row in rows)
      if (row is Map)
        (
          id: '${row['id'] ?? ''}',
          title: '${row['title'] ?? ''}',
          model: '${row['model'] ?? ''}',
          agent: '${row['agent'] ?? ''}',
          projectId: '${row['projectId'] ?? ''}',
          updatedAt: '${row['updatedAt'] ?? ''}',
          archived: row['archived'] == true,
        ),
  ];
}, retry: null);

/// The chats still in play.
List<ChatRow> liveChats(List<ChatRow> all) => [
  for (final chat in all)
    if (!chat.archived) chat,
];

/// The chats put away.
List<ChatRow> archivedChats(List<ChatRow> all) => [
  for (final chat in all)
    if (chat.archived) chat,
];

/// The computer's projects, keyed by id, so a chat row can name the project it
/// belongs to instead of showing a number.
final projectsProvider = FutureProvider<Map<String, ProjectRow>>((ref) async {
  final result = await ref
      .watch(phoneLinkProvider.notifier)
      .call('projects.list');
  final rows = result['projects'];
  if (rows is! List) return const {};
  return {
    for (final row in rows)
      if (row is Map && row['id'] is String)
        row['id'] as String: (
          id: row['id'] as String,
          name: '${row['name'] ?? ''}',
          model: '${row['model'] ?? ''}',
          agent: '${row['agent'] ?? ''}',
        ),
  };
}, retry: null);

/// One page of one conversation.
final transcriptProvider =
    FutureProvider.family<ChatTranscript, TranscriptRequest>((
      ref,
      request,
    ) async {
      final result = await ref.watch(phoneLinkProvider.notifier).call(
        'chats.get',
        {
          'id': request.id,
          if (request.offset != null) 'offset': request.offset,
        },
      );
      final messages = result['messages'];
      return (
        id: request.id,
        lines: [
          for (final message in messages is List ? messages : const [])
            if (message is Map)
              (
                role: '${message['role'] ?? ''}',
                text: '${message['text'] ?? ''}',
                index: _asInt(message['index']) ?? 0,
                media: [
                  for (final item
                      in message['media'] is List
                          ? message['media']! as List
                          : const [])
                    if (item is Map)
                      (
                        kind: '${item['kind'] ?? 'file'}',
                        name: '${item['name'] ?? ''}',
                      ),
                ],
              ),
        ],
        total: _asInt(result['total']) ?? 0,
        offset: _asInt(result['offset']) ?? 0,
        busy: result['busy'] == true,
      );
    }, retry: null);

/// [value] as a whole number, or null when it is anything else.
int? _asInt(Object? value) => switch (value) {
  final int number => number,
  final double number => number.toInt(),
  _ => null,
};
