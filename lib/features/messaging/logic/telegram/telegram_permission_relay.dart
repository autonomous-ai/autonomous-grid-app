import 'dart:async';

import '../../../../infrastructure/api/telegram_bot_api.dart';
import '../../../../infrastructure/api/telegram_wire.dart';
import '../../../../infrastructure/cli/agent_event.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../agents/logic/agent_permission_answers.dart';
import 'telegram_markup.dart';
import 'telegram_rules.dart';

/// A command longer than this is cut in the question: Telegram caps a message
/// at 4096 characters, and nobody reads that much on a phone before tapping.
const int _kShownCommand = 1500;

/// Puts the assistant's permission requests to the person on Telegram, and
/// hands their answer back.
///
/// The reason to host the bot in the app at all: a Telegram chat runs under the
/// same "ask first" as Chat, and the question has to reach whoever can answer.
/// Mirrors the window's own requests ([onPermissions] is fed the same map the
/// window's card reads), so whichever side answers first wins and the other
/// closes — the same arrangement the Grid Panel has.
class TelegramPermissionRelay {
  TelegramPermissionRelay(
    this._api, {
    required this.chatIdOf,
    required this.answer,
    required this.log,
  });

  final TelegramBotApi _api;

  /// The Telegram chat carrying on a Grid chat, for a question raised there.
  /// Lives in the controller so `/sessions` pointing a Telegram chat at a
  /// desktop chat keeps letting that chat's questions reach the phone.
  final int? Function(String conversationId) chatIdOf;

  /// Deliver a choice to the agent — `AgentPermissionController.answer`.
  final void Function(String conversationId, AgentPermissionChoice choice)
  answer;

  final AppLog log;

  /// The question showing on Telegram, by the Grid chat that asked it.
  final Map<String, _Asked> _asked = {};
  int _nextAsk = 1;

  /// The app's open questions changed: ask the new ones on Telegram, and close
  /// the ones that went — answered anywhere, timed out, or their turn ended.
  void onPermissions(Map<String, AgentPermission> open) {
    for (final entry in open.entries) {
      final chatId = chatIdOf(entry.key);
      if (chatId == null) continue;
      final asked = _asked[entry.key];
      if (asked != null && asked.request.id == entry.value.id) continue;
      if (asked != null) _close(asked);
      _ask(entry.key, chatId, entry.value);
    }
    for (final id in [..._asked.keys]) {
      if (open.containsKey(id)) continue;
      final asked = _asked.remove(id);
      if (asked != null) _close(asked);
    }
  }

  /// A button under a question was tapped (by someone already on the list).
  Future<void> onPress(TelegramButtonPress press) async {
    final data = parseTelegramAnswerData(press.data);
    MapEntry<String, _Asked>? target;
    for (final entry in _asked.entries) {
      if (entry.value.chatId == press.chatId && entry.value.ask == data?.ask) {
        target = entry;
      }
    }
    if (data == null || target == null) {
      return _api.answerButton(
        press.callbackId,
        text: 'That question has already closed.',
      );
    }
    target.value.answer = data.choice;
    answer(target.key, data.choice);
    await _api.answerButton(press.callbackId);
  }

  void _ask(String conversationId, int chatId, AgentPermission request) {
    final asked = _Asked(chatId: chatId, request: request, ask: _nextAsk++);
    _asked[conversationId] = asked;
    final buttons = [
      for (final option in permissionAnswersFor(request))
        (
          label: option.label,
          data: telegramAnswerData(asked.ask, option.choice),
        ),
    ];
    unawaited(
      _api
          .sendMessage(
            chatId,
            telegramPermissionText(request),
            html: true,
            // One answer per row: three side by side don't fit a phone.
            rows: [
              for (final button in buttons) [button],
            ],
          )
          .then((id) => asked.messageId = id)
          .catchError((Object error) {
            log.warn('telegram', "couldn't ask on Telegram: $error");
            return 0;
          }),
    );
  }

  /// Take the buttons off a question that is no longer waiting, saying what
  /// became of it.
  void _close(_Asked asked) {
    final messageId = asked.messageId;
    if (messageId == null || messageId == 0) return;
    final chosen = asked.answer;
    final outcome = chosen == null
        ? 'No longer waiting — answered on the computer, or the minute ran '
              'out (which counts as no).'
        : 'You answered: ${kPermissionAnswerLabels[chosen]}.';
    unawaited(
      _api
          .editMessage(
            asked.chatId,
            messageId,
            '${telegramPlainText(telegramPermissionText(asked.request))}'
            '\n\n$outcome',
          )
          .catchError((Object error) {
            log.warn('telegram', "couldn't close a question: $error");
          }),
    );
  }
}

/// The question as it reads on the phone, in Telegram HTML.
String telegramPermissionText(AgentPermission request) {
  final summary = request.summary.trim();
  final what = switch (request.kind) {
    AgentPermissionKind.command =>
      'The assistant wants to run a command:\n'
          '<pre>${telegramEscape(_shorten(request.command ?? summary))}</pre>',
    AgentPermissionKind.edit =>
      'The assistant wants to change a file:\n'
          '<code>${telegramEscape(request.path ?? summary)}</code>',
    AgentPermissionKind.other =>
      'The assistant wants to: ${telegramEscape(summary)}',
  };
  return '$what\n\n<i>No answer within a minute counts as no.</i>';
}

String _shorten(String text) => text.length <= _kShownCommand
    ? text
    : '${text.substring(0, _kShownCommand)}…';

/// One question on one phone. Mutable bookkeeping: the message id arrives after
/// the send, and the answer when a button is tapped.
class _Asked {
  _Asked({required this.chatId, required this.request, required this.ask});

  final int chatId;
  final AgentPermission request;
  final int ask;
  int? messageId;
  AgentPermissionChoice? answer;
}
