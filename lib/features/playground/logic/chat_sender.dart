import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/api/models/media_event.dart';
import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/agent_resume_point.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../provider_node/logic/api_engine_catalog.dart';
import 'chat_message.dart';
import 'image_budget.dart';
import 'media_outputs.dart';
import 'media_transport.dart';
import 'message_media.dart';
import 'playground_request.dart';
import 'responses_transport.dart';

/// A single step in sending one message, streamed by [ChatSender.send]:
/// generation progress, then exactly one terminal [ChatSendSuccess] or
/// [ChatSendFailure]. Modelled as a sealed type so callers switch exhaustively
/// instead of juggling nullable reply/error/progress fields.
sealed class ChatSendUpdate {
  const ChatSendUpdate();
}

/// A media generation is streaming — [progress] is 0–1, [status] the relay's
/// short phase label. Never emitted for plain text chat.
class ChatSendGenerating extends ChatSendUpdate {
  const ChatSendGenerating(this.progress, this.status);
  final double progress;
  final String status;
}

/// The assistant's text as it streams in, token by token. [text] is the *whole*
/// reply so far — cumulative — so the UI redraws the growing bubble by replacing,
/// not appending. Emitted by every text path now: the agents over their own
/// protocols, and the relay chat over SSE. A terminal [ChatSendSuccess] with the
/// final text still follows, so a caller that ignores this shows the whole reply
/// at the end.
class ChatSendStreaming extends ChatSendUpdate {
  const ChatSendStreaming(this.text);
  final String text;
}

/// The agent opened a session for this turn — [sessionId] is the agent's own id
/// for it. The Chat tab holds on to it so it can ask the agent, once it has
/// answered, what it decided to call the conversation: the agent names its own
/// sessions, and that name says far more than the user's first line ("hi").
/// Only the agent sender emits it — an HTTP call to the grid has no session.
class ChatSendAgentSession extends ChatSendUpdate {
  const ChatSendAgentSession(this.sessionId);
  final String sessionId;
}

/// A goal the **agent** is driving has been judged once more and is still not
/// met — [reason] is its evaluator's latest word.
///
/// Only a delegated goal emits this ([GoalOwner]): where the app runs the loop
/// itself it already has the verdict in hand. It arrives mid-turn, because a
/// delegated goal runs many rounds inside one invocation, and the line under
/// the composer is the only sign the user has that it is still moving.
class ChatSendGoalProgress extends ChatSendUpdate {
  const ChatSendGoalProgress({required this.condition, required this.reason});

  /// What the agent restates the condition as. Compared with the goal the app
  /// holds, so a round belonging to a goal the user has since replaced is
  /// dropped rather than written over the new one.
  final String condition;

  final String reason;
}

/// The request finished; [reply] is the assistant turn to append (text for
/// chat, media for a generation).
class ChatSendSuccess extends ChatSendUpdate {
  const ChatSendSuccess(this.reply, {this.outOfSteps = false});
  final ChatMessage reply;

  /// The agent stopped because it used up the tool calls one turn is allowed,
  /// with its plan still unfinished — not because the work was done (see
  /// [agentSpentToolBudget]). A success, because the answer it summarised is a
  /// real answer; flagged, because the chat has to offer to carry on rather than
  /// leave the user to guess why it halted mid-plan.
  final bool outOfSteps;
}

/// The request failed; [error] is a plain-language line safe to show the user.
///
/// [partial] is what the assistant had already produced before it failed — a
/// half-written answer, the plan it laid out — so the caller keeps it beside the
/// error instead of wiping the turn blank. Null when there was nothing worth
/// keeping, or when the "reply" *was* the raw failure (a server error we
/// humanized), which must never be shown as if the assistant had said it.
class ChatSendFailure extends ChatSendUpdate {
  const ChatSendFailure(this.error, {this.partial});
  final String error;
  final ChatMessage? partial;
}

/// Sends one chat/media message and streams its progress + outcome. The single
/// source of truth for *how* a message is dispatched, shared by the Playground
/// dialog and the Chat tab so both route, log and humanize failures identically:
/// - **Text** (and the local-engine smoke test) → OpenAI `chat/completions`.
/// - **Image** → `media/image/generate`, or `media/image/edit` with attachments.
/// - **Video** → `media/video/i2v` (needs one attached starting image).
///
/// It owns no transcript state — the caller passes the full [history] and folds
/// each [ChatSendUpdate] into its own state. Every call is mirrored into the
/// Debug command log.
abstract interface class ChatSender {
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,

    /// The folder the agent may read while it answers — the project this chat was
    /// opened inside. Null falls back to the app's own working folder, and the
    /// API sender ignores it entirely (a relay call has no filesystem).
    String? workdir,

    /// The conversation this turn belongs to, when the caller has one. The agent
    /// sender keeps one live session per conversation, so it can send only the
    /// new turn and let the agent hold the context; switching conversation (a
    /// different id) starts a fresh session. Null for one-off transcripts (the
    /// Playground) and the relay sender, which are stateless.
    String? conversationId,

    /// A per-turn id minted by the caller for this user input. The agent
    /// senders inject it as an `X-Request-Id` request header (Claude Code /
    /// Codex via a per-turn env var) so the relay can attribute every LLM call
    /// this turn makes under one id; the relay sender ignores it (a direct
    /// relay call carries the app's own transport, not a turn id).
    String? turnId,

    /// The project's standing rules for the agent, prepended to the first turn
    /// of a session (the app's `AGENTS.md`). Null/blank for a chat in no project
    /// and ignored by the relay sender, which has no agent to instruct.
    String? instructions,

    /// Send **exactly this** as the turn's prompt, instead of building one from
    /// [history].
    ///
    /// For a slash command the agent runs itself — today only `/goal`, which
    /// Claude Code answers over `-p` (its definition carries
    /// `supportsNonInteractive`). Such a command has to arrive as the first
    /// characters of the prompt: buried under a replayed transcript, the
    /// project's standing rules or Plan mode's preamble, the CLI reads it as
    /// ordinary words and the goal is silently never set.
    ///
    /// It is separate from the message the chat shows, and deliberately: the
    /// transcript keeps the user's own words ("write me a game"), while the wire
    /// carries `/goal write me a game`. A sender with no commands of its own
    /// ignores this and answers [history] as usual.
    String? agentCommand,

    /// Run this as Plan mode's planning turn: read-only, with a preamble asking
    /// the agent to lay out a plan and touch nothing. The agent sender honours
    /// it; the relay sender has no plan/act distinction and ignores it.
    bool planFirst,

    /// How much the agent may do without asking on this turn — the *chat's*
    /// mode, which is not the app's (see `chatApprovalModeProvider`). Passed in
    /// rather than read from a provider because a turn can be dispatched into a
    /// chat the user isn't looking at, and reading "the open chat's mode" there
    /// would run it under a different chat's permissions. Null falls back to
    /// the app's standing choice, for callers with no conversation at all (the
    /// Playground); the relay sender ignores it, having no agent to constrain.
    AgentApprovalMode? approval,

    /// The agent session this conversation can carry on from, written down when
    /// its last turn opened one — or when it was imported from the tool that
    /// opened it. Read by the two senders that resume by id (Claude Code,
    /// Codex), and only when it names their own agent and their own folder.
    ///
    /// Null for a chat with no session behind it, for the Playground, and for
    /// the relay sender, which has nothing to resume.
    AgentResumePoint? resume,
  });
}

/// Wire [ChatSender] through the container so controllers stay testable — a
/// fake sender (or fake transports underneath) swaps in without a live relay.
final chatSenderProvider = Provider<ChatSender>(
  (ref) => DefaultChatSender(ref),
);

/// Builds the user turn to append before sending. Any attached images are saved
/// to [outputsDir] and carried on the turn so they show in the user's own
/// bubble and persist with the conversation — both the images sent to a vision
/// model and the source image(s) for an edit / image-to-video request. For a
/// text (vision) chat [DefaultChatSender] also re-encodes them into the request;
/// for media generation the images ride in the media payload instead, so here
/// they're display-only.
///
/// Attached [files] ride along as they are: they were read when the user
/// attached them, and they stay beside the text rather than inside it so the
/// bubble shows a chip where the model gets the document (see [messageForModel]).
/// [contexts] — what was on screen as Send was pressed — ride the same way.
///
/// [origin] says who this turn came from. It is the user unless the app is
/// carrying on an instruction of theirs — the goal's next step, a loop's beat —
/// and it changes only how the turn is drawn (see [TurnOrigin]).
Future<ChatMessage> buildUserTurn({
  required String text,
  required List<MediaAttachment> attachments,
  required Directory outputsDir,
  List<ChatFile> files = const [],
  List<ChatContext> contexts = const [],
  TurnOrigin origin = TurnOrigin.user,
}) async {
  if (attachments.isEmpty) {
    return ChatMessage(
      role: ChatRole.user,
      text: text,
      files: files,
      contexts: contexts,
      sentAt: DateTime.now(),
      sentBy: origin,
    );
  }
  final media = await saveMediaOutputs([
    for (final a in attachments) a.toMediaFile(),
  ], outputsDir);
  return ChatMessage(
    role: ChatRole.user,
    text: text,
    media: media,
    files: files,
    contexts: contexts,
    sentAt: DateTime.now(),
    sentBy: origin,
  );
}

/// The real [ChatSender], driving the HTTP chat/media transports.
class DefaultChatSender implements ChatSender {
  DefaultChatSender(this._ref);

  final Ref _ref;

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    // A relay call has no filesystem — the project folder means nothing here.
    String? workdir,
    String? conversationId,
    // A relay DIRECT call has no agent turn — the header there comes from the
    // app's own transport, so a turn id is not threaded through here.
    String? turnId,
    // The relay has no agent to instruct, so project rules are irrelevant here.
    String? instructions,
    // A relay call has no agent, so it has no commands to run either.
    String? agentCommand,
    // No plan/act distinction on a relay call — a chat/completions request just
    // answers.
    bool planFirst = false,
    // The relay has no agent, so there are no permissions to constrain.
    AgentApprovalMode? approval,
    // Nothing to resume: every relay call is a whole request on its own.
    AgentResumePoint? resume,
  }) {
    // Every request from both the Playground and the Chat tab funnels through
    // here — the one place that counts a message sent, once, whatever it is.
    _ref
        .read(analyticsProvider)
        .chatMessageSent(model: model, isLocal: localBaseUrl != null);
    // The local smoke test and relay text both hit chat/completions; only the
    // base URL differs (the local engine has no `/relay/v1` prefix).
    if (localBaseUrl != null) {
      return _sendChat(
        endpoint: '$localBaseUrl/v1/chat/completions',
        network: network,
        model: model,
        history: history,
        conversationId: conversationId,
        turnId: turnId,
      );
    }

    switch (modality) {
      case PlaygroundModality.text:
        // Codex seats serve the Responses endpoint ONLY — a `codex:*` model has
        // no chat/completions provider, so a chat request to one 503s ("No
        // providers available for this model"). Route it to `/responses` in the
        // vendor's dialect instead (ADR 0015 D-a/D-b).
        if (isResponsesOnlyModel(model)) {
          return _sendResponses(
            endpoint: '${network.relayBaseUrl}/responses',
            network: network,
            model: model,
            history: history,
          );
        }
        return _sendChat(
          endpoint: '${network.relayBaseUrl}/chat/completions',
          network: network,
          model: model,
          history: history,
          conversationId: conversationId,
          turnId: turnId,
        );
      case PlaygroundModality.image:
        final edit = attachments.isNotEmpty;
        return _sendMedia(
          network: network,
          operation: edit
              ? MediaOperation.imageEdit
              : MediaOperation.imageGenerate,
          payload: edit
              ? imageEditPayload(_lastPrompt(history), attachments)
              : imageGeneratePayload(_lastPrompt(history)),
        );
      case PlaygroundModality.video:
        if (attachments.isEmpty) {
          return Stream.value(
            const ChatSendFailure('Add a starting image to make a video.'),
          );
        }
        return _sendMedia(
          network: network,
          operation: MediaOperation.i2v,
          payload: i2vPayload(_lastPrompt(history), attachments.first),
        );
    }
  }

  /// Streaming chat completion (relay or local). Emits the reply as it arrives
  /// so a slow model fills the bubble token by token instead of after a wait,
  /// then a terminal success. Mirrors the call into the Debug tab and maps
  /// failures to a plain-language line.
  Stream<ChatSendUpdate> _sendChat({
    required String endpoint,
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    String? conversationId,
    String? turnId,
  }) async* {
    final messages = _messagesFor(history, _budgetedImageUri(history));
    final log = _ref.read(commandLogProvider.notifier);
    final id = log.begin(
      CliCallKind.http,
      'POST $endpoint',
      detail: CommandDetail.json(
        chatCompletionsPayload(model: model, messages: messages),
        // A local engine is reached without one; the relay always carries it.
        authorized: network.relayApiKey.isNotEmpty,
      ),
    );

    final answer = StringBuffer();
    await for (final event
        in _ref
            .read(chatTransportProvider)
            .stream(
              endpoint: endpoint,
              apiKey: network.relayApiKey,
              model: model,
              messages: messages,
              conversationId: conversationId,
              turnId: turnId,
            )) {
      switch (event) {
        case ChatDelta(:final text):
          answer.write(text);
          yield ChatSendStreaming(answer.toString());
        case ChatFailed(:final error):
          log.finish(id, exitCode: error.statusCode ?? 0, error: error.message);
          yield ChatSendFailure(
            _friendlyChatError(error, hadImages: _turnHasImages(history)),
          );
          return;
        case ChatDone():
          break;
      }
    }
    log.finish(id, exitCode: 200, responseBody: answer.toString());

    final text = answer.isEmpty ? 'The model returned no text.' : '$answer';
    yield ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: text));
  }

  /// One-shot Responses completion (relay only). Same shape as [_sendChat] — mirror
  /// into the Debug tab, map failures to a plain line — but hits `/responses`
  /// with the vendor's Responses dialect and drains its SSE into one reply.
  Stream<ChatSendUpdate> _sendResponses({
    required String endpoint,
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
  }) async* {
    const instructions = 'You are a helpful assistant.';
    final input = buildResponsesInput(history, _budgetedImageUri(history));
    final log = _ref.read(commandLogProvider.notifier);
    final id = log.begin(
      CliCallKind.http,
      'POST $endpoint',
      detail: CommandDetail.json(
        responsesPayload(
          model: model,
          input: input,
          instructions: instructions,
        ),
        authorized: network.relayApiKey.isNotEmpty,
      ),
    );

    final (reply, error) = await _ref
        .read(responsesTransportProvider)
        .complete(
          endpoint: endpoint,
          apiKey: network.relayApiKey,
          model: model,
          input: input,
          instructions: instructions,
        );
    log.finish(
      id,
      exitCode: error?.statusCode ?? 200,
      error: error?.message,
      responseBody: reply,
    );

    if (error != null) {
      yield ChatSendFailure(
        _friendlyChatError(error, hadImages: _turnHasImages(history)),
      );
      return;
    }
    final answer = (reply == null || reply.isEmpty)
        ? 'The model returned no text.'
        : reply;
    yield ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: answer));
  }

  /// Streams a media generation, surfacing progress as it arrives, then saves
  /// the result to `~/.grid/outputs` and yields it as the assistant turn.
  Stream<ChatSendUpdate> _sendMedia({
    required NetworkCredential network,
    required MediaOperation operation,
    required Map<String, dynamic> payload,
  }) async* {
    final url = '${network.relayBaseUrl}/${operation.path}';
    final log = _ref.read(commandLogProvider.notifier);
    // The payload carries the source images base64-encoded and runs to
    // megabytes; [CommandLogNotifier] clips it before it is kept.
    final id = log.begin(
      CliCallKind.http,
      'POST $url',
      detail: CommandDetail.json(
        payload,
        authorized: network.relayApiKey.isNotEmpty,
      ),
    );

    // Show a generating bubble right away, before the first progress event.
    yield const ChatSendGenerating(0, 'starting');

    MediaError? failure;
    List<MediaFile> result = const [];
    try {
      final events = _ref
          .read(mediaTransportProvider)
          .stream(url: url, apiKey: network.relayApiKey, payload: payload);
      await for (final event in events) {
        switch (event) {
          case MediaProgress(:final progress, :final status):
            yield ChatSendGenerating(_fraction(progress), status);
          case MediaResult(:final files):
            result = files;
          case MediaError():
            failure = event;
        }
      }
    } on Object catch (e) {
      failure = MediaError('$e');
    }

    if (failure != null) {
      log.finish(id, error: failure.message);
      yield ChatSendFailure(failure.message);
      return;
    }
    if (result.isEmpty) {
      log.finish(id, error: 'No media returned.');
      yield const ChatSendFailure('The grid finished but returned no media.');
      return;
    }

    final saved = await saveMediaOutputs(
      result,
      _ref.read(mediaOutputsDirProvider),
    );
    log.finish(id, exitCode: 200);
    if (saved.isEmpty) {
      yield const ChatSendFailure("The generated files couldn't be read.");
      return;
    }
    yield ChatSendSuccess(ChatMessage(role: ChatRole.assistant, media: saved));
  }

  /// The most recent user prompt — the text a media generation renders.
  static String _lastPrompt(List<ChatMessage> history) {
    for (final m in history.reversed) {
      if (m.role == ChatRole.user && m.text.isNotEmpty) return m.text;
    }
    return '';
  }

  /// Builds the OpenAI messages array. Text turns carry a plain-string
  /// `content`; a user turn with attached images becomes a vision `content`
  /// array (text part + each image as a base64 data URI). Empty turns are
  /// skipped.
  static List<Map<String, dynamic>> _messagesFor(
    List<ChatMessage> history,
    String? Function(String path) imageDataUri,
  ) {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'You are a helpful assistant.'},
    ];
    for (final m in history) {
      final role = m.role == ChatRole.user ? 'user' : 'assistant';
      // What the model reads is the turn *plus its documents* — the relay has no
      // filesystem, so a file's text reaching it here is the only way an
      // attachment means anything to a plain model.
      final text = messageForModel(m);
      final images = m.role == ChatRole.user
          ? [
              for (final md in m.media)
                if (md.kind == MediaKind.image) md,
            ]
          : const <ChatMedia>[];

      if (images.isEmpty) {
        if (text.isNotEmpty) messages.add({'role': role, 'content': text});
        continue;
      }

      final content = <Map<String, dynamic>>[
        if (text.isNotEmpty) {'type': 'text', 'text': text},
        for (final img in images)
          if (imageDataUri(img.path) case final uri?)
            {
              'type': 'image_url',
              'image_url': {'url': uri},
            },
      ];
      if (content.isEmpty) continue;
      messages.add({'role': role, 'content': content});
    }
    return messages;
  }

  /// The picture encoder for one request, stopped at [kImagePayloadBudget].
  ///
  /// The whole conversation goes out again every turn, so a chat that has
  /// collected screenshots over an afternoon eventually builds a body the relay
  /// refuses outright — and refuses it for the *new* question, which may carry
  /// no picture at all. The newest pictures are kept and the oldest left out;
  /// what was dropped goes to the log, so a thin request is never mistaken for
  /// a complete one.
  String? Function(String path) _budgetedImageUri(List<ChatMessage> history) {
    final (:keep, :dropped) = imagesWithinBudget(history, sizeOf: _imageBytes);
    if (dropped > 0) {
      _ref
          .read(appLogProvider)
          .warn(
            'api',
            'chat: left $dropped older picture(s) out of the request — a body '
                'holds ${kImagePayloadBudget ~/ 1000000} MB of pictures.',
          );
    }
    return (path) => keep.contains(path) ? _imageDataUri(path) : null;
  }

  /// The bytes an attached picture takes on disk, or -1 when it is gone — the
  /// budget must not spend anything on a file the encoder will drop anyway.
  static int _imageBytes(String path) {
    try {
      return File(path).lengthSync();
    } on Object {
      return -1;
    }
  }

  /// A `data:` URI for an on-disk image, or null when the file can't be read
  /// (deleted since it was attached) — the image is then simply dropped.
  static String? _imageDataUri(String path) {
    try {
      final bytes = File(path).readAsBytesSync();
      return 'data:${_mimeForPath(path)};base64,${base64Encode(bytes)}';
    } on Object {
      return null;
    }
  }

  static String _mimeForPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      _ => 'image/png',
    };
  }

  /// Turns a transport failure into one plain line; the raw detail stays in the
  /// Debug log. We surface the relay's actual reason (out of credit, expired
  /// session) rather than a blanket "is a model running?" guess.
  ///
  /// [hadImages] is what lets the one genuinely confusing failure read plainly:
  /// a picture sent to a text-only model. There's no per-model "can see images"
  /// flag on the grid to check before sending, so the request goes out and the
  /// backend rejects it — as a 400/422, or with an "image"/"content" complaint
  /// whose wording is different on every engine. Rather than show any of those,
  /// when the turn carried an image *and* the failure looks like that rejection,
  /// say the one thing the user can act on.
  static String _friendlyChatError(
    ChatTransportError error, {
    bool hadImages = false,
  }) {
    if (error.statusCode == 401 || error.statusCode == 403) {
      return 'Your session expired — please sign in again.';
    }
    final detail = error.message.trim();
    if (detail.toLowerCase().contains('insufficient balance')) {
      return "You're out of credit on this grid — top up your balance, then "
          'try again.';
    }
    if (_looksTooLarge(error)) {
      return 'That message is too big to send — the pictures and files on it '
          'are over the limit. Remove one, or start a new chat and ask again '
          'there.';
    }
    if (hadImages && _looksLikeNoVision(error)) {
      return "This model can't read images. Remove the picture and ask in "
          'text, or pick a model that can see images, then send again.';
    }
    if (detail.isEmpty) {
      return "Couldn't get a reply. Make sure a model is running on this grid, "
          'then try again.';
    }
    return "Couldn't get a reply: $detail";
  }

  /// Whether the request was refused for its **size** rather than its content.
  ///
  /// The relay answers a body over its ceiling with `Request body exceeds
  /// 20000000 bytes`; a proxy in front of one answers 413. Either way the user
  /// needs to hear about what they attached, not about the model — and pictures
  /// are shrunk on the way into the composer precisely so this stays rare.
  static bool _looksTooLarge(ChatTransportError error) {
    if (error.statusCode == 413) return true;
    final lower = error.message.toLowerCase();
    return lower.contains('request body exceeds') ||
        lower.contains('payload too large') ||
        lower.contains('request entity too large');
  }

  /// Whether a failed image turn failed *because the model can't take images*.
  ///
  /// Two signals, either enough: the backend named it (its wording varies, so
  /// this matches the words that recur — image, vision, multimodal, content
  /// type), or it answered a plain 400/422 — the "bad request" a text model
  /// returns when handed image parts it doesn't understand. A 5xx, a timeout or
  /// a rate-limit is a different problem and keeps its own message, so those are
  /// deliberately left out.
  static bool _looksLikeNoVision(ChatTransportError error) {
    final lower = error.message.toLowerCase();
    const phrases = [
      'image',
      'vision',
      'multimodal',
      'content type',
      'unsupported content',
      'invalid content',
    ];
    if (phrases.any(lower.contains)) return true;
    return error.statusCode == 400 || error.statusCode == 422;
  }

  /// Whether this turn actually carried an image the model was asked to read —
  /// the precondition for [_friendlyChatError]'s vision message.
  ///
  /// The **last** user message, not any of them: it is the turn being sent. A
  /// chat that once carried a picture goes on carrying it in its history, and
  /// asking `any` there told a user whose plain-text turn hit a 400 for some
  /// other reason — context length, a bad model id — to "remove the picture"
  /// from a message that had none, hiding the real reason behind it.
  static bool _turnHasImages(List<ChatMessage> history) {
    for (final message in history.reversed) {
      if (message.role != ChatRole.user) continue;
      return message.media.any((md) => md.kind == MediaKind.image);
    }
    return false;
  }

  /// Normalizes the relay's progress number to 0–1, tolerating either a percent
  /// (0–100, as the CLI prints) or an already-fractional value.
  static double _fraction(double progress) =>
      (progress <= 1 ? progress : progress / 100).clamp(0.0, 1.0);
}
