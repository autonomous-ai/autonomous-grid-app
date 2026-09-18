/// Putting a message from a paired phone into a chat on this computer.
///
/// The third surface to do this, after the Telegram bot and the Panel, and it
/// works the way they do: **through [chatSessionsProvider], not beside it.**
/// The chat is one the window shows, so the conversation keeps its history and
/// its context, and it is answered by the same assistant and model the person
/// picked there rather than by a second, lesser copy of the Chat tab.
///
/// What is different here is who is asking. Telegram's gate is a list of user
/// ids; this one is a per-device switch on the paired phone
/// ([PairedDevice.mayAct]), checked on every call rather than once per session.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/pairing_host/mobile_chat_rpc.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../auth/logic/session_controller.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../chat/logic/chat_settled.dart';
import '../../chat/logic/conversation.dart';
import '../../chat/logic/file_attachments.dart';
import '../../chat/logic/turn_model.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/playground_request.dart';
import '../../projects/logic/project.dart';

/// Starts a turn in chat [chatId] carrying [text], and returns before it lands.
///
/// Returns null when the turn is on its way, or **a sentence to show the
/// person** when it cannot start. A sentence rather than an exception because
/// the phone is told exactly this string: the two reasons a send fails here are
/// both things somebody can go and fix at the computer, and "something went
/// wrong" would hide which one it is.
///
/// Deliberately does not wait for the answer. A turn takes tens of seconds and
/// the phone is holding a request open; the phone watches the `busy` flag on
/// the transcript instead, which is also what lets it show the answer arriving
/// rather than one blank wait.
Future<String?> startPhoneTurn(
  Ref ref, {
  required String chatId,
  required String text,
  List<PhoneAttachment> files = const [],
}) async {
  final network = ref.read(selectedNetworkProvider);
  if (network == null) {
    return "Your computer isn't signed in to a grid right now.";
  }
  final chat = _find(ref, chatId);
  final model = firstModelChoice([
    chat?.model,
    ref.read(projectByIdProvider(chat?.projectId))?.model,
    ref.read(chatPrefsProvider).model,
  ]);
  if (model.isEmpty) {
    return 'No model is running on this grid right now. Start one in Grid on '
        'your computer, then send this again.';
  }
  unawaited(_run(ref, chatId: chatId, text: text, model: model, files: files));
  return null;
}

/// Starts a new chat carrying [text], and returns its id.
///
/// Created **and sent into** in one step on purpose. A chat with no messages is
/// not written to disk, so a phone that made an empty one and then sent to it
/// would be answered "that chat is not on this computer" by the very computer
/// that had just made it.
///
/// Returns the new chat's id, or null with a sentence in [problem] — the record
/// rather than an exception, for the reason [startPhoneTurn] returns a string.
Future<({String? id, String? problem})> startPhoneChat(
  Ref ref, {
  required String text,
  String? projectId,
  List<PhoneAttachment> files = const [],
}) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return (id: null, problem: 'Say something first.');
  final id = '${DateTime.now().microsecondsSinceEpoch}';
  ref
      .read(chatSessionsProvider.notifier)
      .ensureBackgroundChat(
        id: id,
        title: _titleFrom(trimmed),
        // The computer's standing choice, never a mode the phone picked: a new
        // chat is exactly where an escalation would be easiest to slip in.
        approval: ref.read(chatPrefsProvider).approval,
        projectId: projectId,
      );
  final problem = await startPhoneTurn(
    ref,
    chatId: id,
    text: trimmed,
    files: files,
  );
  return (id: problem == null ? id : null, problem: problem);
}

/// A chat's name, taken from the message that started it.
///
/// One line and short: the whole message would be a sidebar row the width of a
/// paragraph, and a chat named after its first question is how the desktop's
/// own untitled chats read before a model renames them.
String _titleFrom(String text) {
  final line = text.split('\n').first.trim();
  return line.length <= 60 ? line : '${line.substring(0, 57)}…';
}

/// Whether an answer is still being written in [chatId].
///
/// Synchronous because the phone asks for it with every page of the transcript,
/// and it is one field of state the window already keeps.
bool phoneChatIsBusy(Ref ref, String chatId) =>
    ref.read(chatSessionsProvider).sendingFor(chatId);

/// The answer being written in [chatId] right now, as far as it has got.
///
/// **This is why the phone showed a spinner and nothing else while the computer
/// worked.** A turn is not written to disk until it finishes, and the phone
/// reads the transcript from disk — so for the thirty seconds an agent spends
/// on a question there was, from the phone's side, nothing to read. The window
/// was not reading a file: it holds the reply so far in [SendStreaming].
///
/// Empty when nothing is streaming, which the phone shows as no bubble rather
/// than an empty one.
String phoneChatStreaming(Ref ref, String chatId) =>
    switch (ref.read(chatSessionsProvider).phaseFor(chatId)) {
      SendStreaming(:final text) => text,
      // A turn that has started but produced no token yet. The phone already
      // has `busy` for that, and an empty bubble says less than a spinner.
      _ => '',
    };

Future<void> _run(
  Ref ref, {
  required String chatId,
  required String text,
  required String model,
  required List<PhoneAttachment> files,
}) async {
  try {
    // Somebody may be typing in this chat at the computer; their turn first.
    // Without this the phone's message interleaves with theirs and both
    // assistants answer half a conversation.
    await chatSettled(ref, chatId);
    final network = ref.read(selectedNetworkProvider);
    if (network == null) return;
    final attached = await _attachmentsFrom(files);
    await ref
        .read(chatSessionsProvider.notifier)
        .send(
          network: network,
          model: model,
          message: text,
          into: chatId,
          attachments: attached.images,
          files: attached.documents,
          // A plan waits on a bar only the window has. From a phone the
          // assistant asks before each action instead, as it does after an
          // approval — the same choice the Telegram lane makes.
          planFirst: false,
        );
  } on Object catch (error) {
    // Nobody is awaiting this, so an unlogged failure is a message that
    // vanished: the phone sees `busy` go false and an answer that never came.
    ref.read(appLogProvider).warn('phone', "couldn't send: $error");
  }
}

/// Splits what the phone sent into pictures and documents.
///
/// By extension, using the same list the composer's own file dialog filters by
/// ([kImageExtensions]) — so a photo sent from a phone becomes the same kind of
/// attachment as one dropped on the window, and reaches a model that can see it
/// rather than arriving as a file whose text could not be read.
///
/// A document goes through [readChatFile], the composer's own reader, which is
/// what pulls the text out of a PDF or a `.docx`. Reimplementing that here
/// would be a second extractor to keep in step with the first.
Future<({List<MediaAttachment> images, List<ChatFile> documents})>
_attachmentsFrom(List<PhoneAttachment> files) async {
  final images = <MediaAttachment>[];
  final documents = <ChatFile>[];
  for (final attachment in files) {
    if (_isImage(attachment.name)) {
      final bytes = await File(attachment.path).readAsBytes();
      images.add(MediaAttachment(filename: attachment.name, bytes: bytes));
      continue;
    }
    final document = await readChatFile(attachment.path);
    if (document != null) documents.add(document);
  }
  return (images: images, documents: documents);
}

bool _isImage(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return kImageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// The conversation [id] names, or null when the window does not have it.
Conversation? _find(Ref ref, String id) {
  for (final conversation in ref.read(chatSessionsProvider).conversations) {
    if (conversation.id == id) return conversation;
  }
  return null;
}
