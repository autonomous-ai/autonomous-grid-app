import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/feedback_client.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/feedback_outbox.dart';
import '../../auth/logic/session_controller.dart';
import 'feedback_draft.dart';

/// Where a submission is: nothing happening, in flight, or stopped with a
/// reason. A sealed set so the dialog's button and its error line are driven by
/// one value rather than by two booleans that can disagree.
///
/// There is no `sent` case on purpose — success closes the dialog, and the
/// notifier that outlives it shouldn't hold a state nobody will clear.
sealed class FeedbackSendState {
  const FeedbackSendState();
}

/// Nothing in flight — the form is the user's.
class FeedbackIdle extends FeedbackSendState {
  const FeedbackIdle();
}

/// The request is out; the form is locked and the button spins.
class FeedbackSending extends FeedbackSendState {
  const FeedbackSending();
}

/// The send stopped. [message] is what the dialog shows; [savedPath] is the
/// local copy that was kept, or null when even saving failed — which is the
/// only case where the user's words exist nowhere but the open text field, and
/// the dialog says so rather than inviting them to close it.
class FeedbackFailed extends FeedbackSendState {
  const FeedbackFailed(this.message, {this.savedPath});

  final String message;
  final String? savedPath;
}

/// Submits one piece of feedback and reports what happened.
///
/// Keeps the two failure duties together, because they belong together: the
/// user gets one plain sentence, and the raw status/body goes to the Debug tab
/// and the durable app log. A humanised message is never the only record.
final feedbackControllerProvider =
    NotifierProvider<FeedbackController, FeedbackSendState>(
      FeedbackController.new,
    );

class FeedbackController extends Notifier<FeedbackSendState> {
  @override
  FeedbackSendState build() => const FeedbackIdle();

  /// Clears a previous failure so a reopened dialog starts clean.
  void reset() => state = const FeedbackIdle();

  /// Sends [draft]. Returns true when the server took it; on false, [state] is a
  /// [FeedbackFailed] carrying the reason and the local copy's path.
  ///
  /// [logsZip] is the diagnostic-log bundle, attached only when the user left
  /// the "Attach diagnostic logs" switch on — the dialog gathers it and hands it
  /// down. Null/empty means a plain JSON send. The logs already live on the
  /// user's disk, so a failed send needn't keep a second copy of them; only the
  /// [FeedbackOutbox] payload is saved.
  Future<bool> send(FeedbackDraft draft, {List<int>? logsZip}) async {
    if (state is FeedbackSending) return false;
    state = const FeedbackSending();

    final payload = feedbackPayload(draft, now: DateTime.now());
    final token = ref.read(sessionProvider).sessionToken;
    if (token == null || token.isEmpty) {
      return _failed(
        payload,
        "You're signed out, so this can't be sent right now.",
      );
    }

    final apiUrl = ref.read(gridApiUrlProvider);
    final attaching = logsZip != null && logsZip.isNotEmpty;
    final log = ref.read(commandLogProvider.notifier);
    final logId = log.begin(
      CliCallKind.http,
      'POST ${HttpFeedbackClient.endpoint(apiUrl)}'
      '${attaching ? ' (+logs ${logsZip.length}B)' : ''}',
      detail: CommandDetail.json(payload, authorized: true),
    );

    final error = await ref
        .read(feedbackClientProvider)
        .send(
          apiUrl: apiUrl,
          sessionToken: token,
          payload: payload,
          logsZip: logsZip,
        );

    log.finish(
      logId,
      exitCode: error?.statusCode ?? (error == null ? 200 : null),
      error: error?.debugDetail,
    );

    if (error == null) {
      ref
          .read(appLogProvider)
          .info(
            'api',
            'feedback sent (${draft.kind.id}${attaching ? ', +logs' : ''})',
          );
      state = const FeedbackIdle();
      return true;
    }
    return _failed(payload, error.message, detail: error.debugDetail);
  }

  /// Keeps a local copy of [payload], records the raw [detail], and moves to
  /// [FeedbackFailed]. Always returns false, so callers can `return _failed(…)`.
  bool _failed(Map<String, dynamic> payload, String message, {String? detail}) {
    final saved = ref
        .read(feedbackOutboxProvider)
        .save(payload, now: DateTime.now());
    ref
        .read(appLogProvider)
        .warn('api', 'feedback failed: ${detail ?? message}');
    state = FeedbackFailed(message, savedPath: saved?.path);
    return false;
  }
}
