import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../playground/logic/one_shot_target.dart';

/// How long the router may take before the app falls back to picking itself.
///
/// Nobody is watching a spinner here — the panel is holding a "Sending…" overlay
/// and the user is waiting to find out where their sentence went. So this wants
/// to be short, and **12 seconds was too short**: measured on 2026-08-17 against
/// the hosted relay, the routing call itself returned 200 OK in 12s — one second
/// after the app had given up on it — and a headline written over the same relay
/// in the same minute took 1m16s. The sentence then went to the fallback project,
/// which is the failure this whole file exists to prevent, and it read as the
/// model choosing wrongly when the model had in fact chosen correctly and been
/// hung up on.
///
/// Thirty seconds is not a target, it is the ceiling: a local engine answers this
/// prompt in under a second, and the number only matters on a machine talking to
/// a relay across the internet. Waiting is the cheaper mistake — a wrong project
/// is a turn someone has to notice, stop, and say again.
const Duration kPanelRouteDeadline = Duration(seconds: 30);

/// How many chats the router is shown at once.
///
/// A tile per chat means the machine can have a hundred of them, and the whole
/// list is neither affordable nor useful: the model would be asked to hold every
/// conversation on the computer in mind to place one sentence, and long lists
/// are where it starts picking on surface word-matches. Twenty, from the front
/// of the panel's own tile order — which is "talked in most recently" — is where
/// a spoken sentence belongs nearly every time.
///
/// The prompt says the list was cut, so a model that recognises none of them
/// still answers with the closest rather than inventing one.
const int kPanelRouteCandidates = 20;

/// Above this the app treats the pick as settled and dispatches; below it, the
/// panel is asked to confirm.
///
/// The bands come from the reference: 0.85+ means the name and/or the recent work
/// clearly match, ~0.6 is reasonable but not certain, ~0.3 is "nothing fits, this
/// is the closest". A guess in the bottom two bands dispatching itself into a real
/// repository is the failure the confirm step exists to prevent.
const double kPanelRouteConfident = 0.85;

/// One conversation the router may choose between.
class PanelRouteCandidate {
  const PanelRouteCandidate({
    required this.id,
    required this.name,
    this.recent = '',
  });

  final String id;
  final String name;

  /// The chat's last few headlines, newest first, joined. Empty when it has no
  /// history — which the prompt says out loud rather than leaving blank.
  final String recent;
}

/// Where the router decided a spoken sentence belongs.
class PanelRouteDecision {
  const PanelRouteDecision({
    required this.chatId,
    required this.confidence,
    required this.reason,
  });

  final String chatId;

  /// 0..1. Drives whether the panel is asked to confirm.
  final double confidence;

  /// A line for the log — why this project. At most a dozen words by the prompt,
  /// clipped here regardless.
  final String reason;

  bool get isConfident => confidence >= kPanelRouteConfident;
}

/// Picks the project a spoken sentence belongs to.
///
/// Ported from the reference implementation (`autonomous-code`,
/// `machine-node/brain/src/prefrontal/voiceRouter.ts`), which had already learned
/// the two things that make this work: **the name is the strongest signal** —
/// people name a project after the thing it is — and **recent activity breaks the
/// ties** the names leave. Hence the history in [PanelRouteCandidate.recent].
///
/// It **always picks one**. There is no "none" and no declining: the sentence has
/// already been spoken and transcribed, and answering "I couldn't tell" strands it
/// with nothing for the user to do but say it again. A bad fit comes back as the
/// closest project with a low confidence, which is a thing the caller can act on.
class PanelVoiceRouter {
  const PanelVoiceRouter(this._ref);

  final Ref _ref;

  /// The project [transcript] belongs to, or null when there was nobody to ask
  /// and no obvious answer — the caller then falls back to its own guess.
  Future<PanelRouteDecision?> route(
    String transcript,
    List<PanelRouteCandidate> candidates,
  ) async {
    if (candidates.isEmpty) return null;
    // No model needed to choose from one. Skipped rather than asked, because the
    // answer cannot be wrong and the call costs a second of someone's attention.
    if (candidates.length == 1) {
      return PanelRouteDecision(
        chatId: candidates.first.id,
        confidence: 1,
        reason: 'the only project on this computer',
      );
    }

    final target = resolveOneShotTarget(_ref);
    if (target == null) return null;

    final prompt = buildPanelRoutePrompt(transcript, candidates);
    final messages = [
      {'role': 'user', 'content': prompt},
    ];
    final log = _ref.read(commandLogProvider.notifier);
    final id = log.begin(
      CliCallKind.http,
      'POST ${target.endpoint}',
      detail: CommandDetail.json(
        chatCompletionsPayload(model: target.model, messages: messages),
        authorized: target.apiKey.isNotEmpty,
      ),
    );
    final (reply, failure) = await _ref
        .read(chatTransportProvider)
        .complete(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
          messages: messages,
        );
    if (!_ref.mounted) return null;
    log.finish(
      id,
      exitCode: failure?.statusCode ?? 200,
      error: failure?.message,
      responseBody: reply,
    );
    if (failure != null) return null;
    return parsePanelRoute(reply ?? '', candidates);
  }
}

final panelVoiceRouterProvider = Provider<PanelVoiceRouter>(
  (ref) => PanelVoiceRouter(ref),
);

/// The router's prompt. Pure, so the wording can be tested without a model.
String buildPanelRoutePrompt(
  String transcript,
  List<PanelRouteCandidate> candidates,
) {
  final lines = candidates
      .map(
        (c) =>
            '- id=${c.id} | name="${c.name}" | recent: '
            '${c.recent.trim().isEmpty ? '(no activity yet)' : c.recent.trim()}',
      )
      .join('\n');
  return 'You are a ROUTER. Assign ONE incoming voice task to the single best-fit '
      'conversation from the fixed list below. The list is the most recently '
      'used conversations on this computer and MAY NOT contain the ideal one. '
      'You MUST always choose exactly one from the list — there is NO "none" '
      'option and you may NOT decline. Each entry is "<chat title> — <project>"; '
      'both matter, and the TITLE is the stronger signal because a chat is named '
      "after what it is about. Each one's RECENT activity disambiguates when "
      'titles alone are ambiguous. If nothing matches well, still pick the '
      'CLOSEST and give it a low confidence.\n\n'
      'Voice task (verbatim; may be Vietnamese — do NOT translate it): '
      '"$transcript"\n\n'
      'Conversations:\n$lines\n\n'
      'Always pick exactly one id from the list above. Set confidence '
      '0..1 for how good the fit is:\n'
      '- 0.85+ when the title and/or recent activity clearly match\n'
      "- ~0.6 when it's a reasonable but not certain match\n"
      '- ~0.3 when nothing fits well but this is the closest one.\n\n'
      'Respond with ONLY a single JSON object, no prose, no markdown fence:\n'
      '{"chatId":"<one id from the list>","confidence":<0..1>,'
      '"reason":"<max 12 words>"}';
}

/// Read the router's answer, defensively.
///
/// The model is told to emit bare JSON and mostly does, but a stray fence or a
/// sentence in front of it must not lose the decision — so the first `{…}` block
/// is extracted rather than the whole reply parsed.
///
/// **Anything unusable resolves to the FIRST candidate with a capped confidence**,
/// never to nothing. The caller is holding a transcribed sentence: it needs a
/// project to offer, and "the closest one, and I am not sure" is an answer a
/// person can correct. Callers pass the candidates in the order the app itself
/// lists them, so the fallback is the same project the app would have guessed
/// without a router at all.
PanelRouteDecision parsePanelRoute(
  String raw,
  List<PanelRouteCandidate> candidates,
) {
  final ids = {for (final c in candidates) c.id};
  final fallback = PanelRouteDecision(
    chatId: candidates.first.id,
    confidence: 0,
    reason: 'closest project (the router did not answer)',
  );
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return fallback;
  Object? decoded;
  try {
    decoded = jsonDecode(raw.substring(start, end + 1));
  } on FormatException {
    return fallback;
  }
  if (decoded is! Map) return fallback;

  final chatId = '${decoded['chatId'] ?? ''}'.trim();
  final confidence = switch (decoded['confidence']) {
    final num value => value.toDouble(),
    final String value => double.tryParse(value) ?? 0,
    _ => 0.0,
  }.clamp(0.0, 1.0);
  final reason = '${decoded['reason'] ?? ''}'.trim();
  final clipped = reason.length <= 120 ? reason : reason.substring(0, 120);

  // An id the app never offered is the model inventing a project. Treated as a
  // parse failure rather than trusted, but its confidence is capped instead of
  // discarded: it still read the list, so its uncertainty is worth keeping.
  if (chatId.isEmpty || !ids.contains(chatId)) {
    return PanelRouteDecision(
      chatId: candidates.first.id,
      confidence: confidence < 0.3 ? confidence : 0.3,
      reason: clipped.isEmpty ? 'closest chat' : clipped,
    );
  }
  return PanelRouteDecision(
    chatId: chatId,
    confidence: confidence,
    reason: clipped,
  );
}
