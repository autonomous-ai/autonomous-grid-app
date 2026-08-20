import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../chat/logic/conversation.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/one_shot_target.dart';

/// The headline's budget, in words.
///
/// ~12-15 words, ONE complete sentence. Twenty overflowed the device tile, which
/// is where this number comes from — it is a measurement of the glass, not a
/// taste in prose.
const int kPanelRecapMaxWords = 15;

/// The body's budget, in words. What the detail reader shows.
const int kPanelSummaryMaxWords = 120;

/// How much of the assistant's message the model is shown.
///
/// A turn can be an hour of work; the answer wanted from it is two lines. Past
/// this the summary is decided by what came last anyway — so the TAIL is kept,
/// not the head: a long turn ends with its conclusion.
const int kPanelSummarySourceLimit = 12000;

/// How long the panel may sit on "Summarizing…" before the turn is closed out
/// with the cheap recap instead.
///
/// Measured, not chosen: **20 seconds was wrong.** A grid's own model answered
/// this prompt in a little over a minute on 2026-08-17, so the deadline fired
/// every time, the tile settled on the cheap recap — which is the state this
/// whole design exists to avoid — and the real headline arrived afterwards to be
/// thrown away.
///
/// It can be generous because the device is **held awake** while the write runs
/// ([kPanelSummarizingBeat]) rather than being raced. What the deadline bounds is
/// not the device's patience, it is how long the user watches a finished turn say
/// it is still reading.
const Duration kPanelSummaryDeadline = Duration(seconds: 90);

/// How often `turn.summarizing` is repeated while the headline is being written.
///
/// The device clears a busy tile after **25 s** with no message
/// (`ui_prune_stale_busy`), so a write that outlives that has to keep saying so.
/// The reference does exactly this — it re-emits `processing` every ~5 s,
/// "covering the turn AND the trailing Summarizing… window" — and the first
/// attempt here skipped it by bounding the write under 25 s instead, which is
/// what made the deadline too tight to be useful.
///
/// Five seconds gives the sweep four beats to miss before it decides the app is
/// gone, which is the tolerance it was written for.
const Duration kPanelSummarizingBeat = Duration(seconds: 5);

/// How much of the user's own request rides along.
///
/// Flattened and capped so a pasted stack trace cannot dominate the prompt and
/// push the assistant's message — where every fact must come from — out of view.
const int kPanelAskLimit = 400;

/// A turn's two readings: a headline for the tile, a paragraph for the reader.
///
/// Produced by ONE model call and split apart afterwards, because they are two
/// lengths of the same judgement. Asking twice would let the two disagree about
/// what the turn was even about.
class PanelTurnSummary {
  const PanelTurnSummary({required this.recap, required this.summary});

  /// At most [kPanelRecapMaxWords] words. Never ends in an ellipsis.
  final String recap;

  /// At most [kPanelSummaryMaxWords] words. Empty when the model gave only a
  /// headline, which is a fine answer for a one-line turn.
  final String summary;
}

/// Writes a finished turn's headline and summary for the panel.
///
/// One blocking `chat/completions` call through the shared [ChatTransport], at
/// the same target as every other one-shot in the app ([resolveOneShotTarget]):
/// the local engine when one is serving, else the grid's relay.
///
/// **The turn does not end on the panel until this answers.** The tile is left in
/// the working state it is already in (`turn.summarizing`, repeated on
/// [kPanelSummarizingBeat] so the device does not sweep it away) and the headline
/// is what closes it. That is the whole point: a placeholder recap shown for the
/// few seconds this takes and then swapped is not missing information, it is
/// **wrong** information, on a screen someone reads from across the room.
///
/// It is still *optional*, and every failure has to be survivable — no model
/// reachable, the call refused, [kPanelSummaryDeadline] elapsed. The caller then
/// closes the turn with the cheap one-line recap instead, because a tile that
/// works forever is the one outcome worse than a plain sentence.
class PanelSummaryWriter {
  const PanelSummaryWriter(this._ref);

  final Ref _ref;

  /// The two readings of the last turn in [chat]. Exactly one half of the pair
  /// is non-null.
  ///
  /// [budget] is the whole window the caller will wait: it is what decides
  /// whether there is still room for a second call after a language drift.
  Future<(PanelTurnSummary? written, String? error)> write(
    Conversation chat, {
    Duration budget = kPanelSummaryDeadline,
  }) async {
    final said = panelSummarySourceOf(chat);
    if (said.isEmpty) return (null, 'That turn left nothing to summarise.');

    final target = resolveOneShotTarget(_ref);
    if (target == null) return (null, noModelReady('write the summary'));

    final clock = Stopwatch()..start();
    final ask = panelSummaryAskOf(chat);
    final (raw, error) = await _ask(target, panelSummaryPrompt(said, ask));
    if (error != null) return (null, error);

    var out = raw!;
    // The output is supposed to mirror the language of its two inputs. Checked
    // by comparing writing systems rather than by naming a language: a word
    // list per language would need maintaining and would only ever be checked
    // in one direction.
    if (panelLanguageDrifted('$ask $said', out)) {
      // Only if there is room to finish one. A retry started with seconds left
      // is a second call whose answer arrives after the caller has given up and
      // settled for the cheap recap — the user's tokens spent on a sentence
      // nobody will read. Measured 2026-08-17: the first call took over a minute
      // and the retry then ran on past the deadline.
      final left = budget - clock.elapsed;
      if (left < clock.elapsed) {
        _ref
            .read(appLogProvider)
            .warn(
              'panel',
              'The summary came back in another language, and there is no time to '
                  'ask again (${clock.elapsed.inSeconds}s of '
                  '${budget.inSeconds}s spent) — sending it as it is',
            );
      } else {
        _ref
            .read(appLogProvider)
            .warn(
              'panel',
              'The summary came back in another language; retrying',
            );
        final (retry, retryError) = await _ask(
          target,
          '${panelSummaryPrompt(said, ask)}\n\n$kPanelSummaryRetryNote',
        );
        // A failed retry is not a failed summary: the first answer was in the
        // wrong language, not wrong. Better a good sentence in the wrong
        // language than a blank screen.
        if (retryError == null) out = retry!;
      }
    }

    final split = splitPanelSummary(out);
    if (split.recap.isEmpty) {
      return (null, "The model didn't answer with a headline.");
    }
    return (split, null);
  }

  Future<(String? reply, String? error)> _ask(
    OneShotTarget target,
    String prompt,
  ) async {
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
    // Nobody awaits this call, so the app can be quit in the middle of it and
    // the Debug tab's entry is no reason to fail on the way out.
    if (!_ref.mounted) return (null, 'Grid closed before the summary landed.');
    log.finish(
      id,
      exitCode: failure?.statusCode ?? 200,
      error: failure?.message,
      responseBody: reply,
    );
    if (failure != null) {
      return (null, friendlyOneShotError(failure, what: 'write the summary'));
    }
    return (reply ?? '', null);
  }
}

/// Wired through the container so the panel stays testable — a fake transport
/// swaps in without a live model.
final panelSummaryWriterProvider = Provider<PanelSummaryWriter>(
  (ref) => PanelSummaryWriter(ref),
);

/// What the model is asked to re-voice: the last thing the assistant said.
///
/// Read off the saved transcript rather than the live run feed, because by the
/// time a turn has ended the feed has done its job and the message is what
/// survives. Only the prose: the steps are what the *tile* already drew while
/// the turn ran, and a headline built from tool names reads like a build log.
///
/// Pure, so what the model is shown can be checked without a model.
String panelSummarySourceOf(Conversation chat) {
  for (final message in chat.messages.reversed) {
    if (message.role != ChatRole.assistant) continue;
    final said = message.text.trim();
    if (said.isEmpty) continue;
    if (said.length <= kPanelSummarySourceLimit) return said;
    // The TAIL, not the head — a long turn ends with its conclusion, and the
    // conclusion is the whole point of a headline.
    return said.substring(said.length - kPanelSummarySourceLimit);
  }
  return '';
}

/// The request that turn was answering, or '' when it cannot be found.
///
/// The user's own words are what make a headline answer the question instead of
/// describing the topic — asked a price, lead with the price. Taken as the last
/// user message before the assistant's, so a queued follow-up further up the
/// transcript cannot claim a turn it did not start.
String panelSummaryAskOf(Conversation chat) {
  var seenAssistant = false;
  for (final message in chat.messages.reversed) {
    if (message.role == ChatRole.assistant) {
      if (message.text.trim().isNotEmpty) seenAssistant = true;
      continue;
    }
    if (!seenAssistant || message.role != ChatRole.user) continue;
    final ask = message.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (ask.isEmpty) continue;
    return ask.length <= kPanelAskLimit
        ? ask
        : ask.substring(0, kPanelAskLimit);
  }
  return '';
}

/// Appended when the first answer came back in the wrong language.
const String kPanelSummaryRetryNote =
    'RETRY: your previous output was NOT in the same language as the '
    "user's request and the assistant message. Rewrite it in exactly that "
    'language — same script and same diacritics — preserving the required '
    'two-part format.';

/// The prompt, ported from the reference implementation that has been through
/// this on real devices (`autonomous-code`, `machine-node/brain/prefrontal/recap.ts`).
///
/// It guards two failure modes, both seen in the wild there:
///
///  1. **Meta-task leak** — asked to write in the first person, the model takes
///     "I" to mean *itself* and puts its plan for the summarising job into the
///     headline slot ("I need to convert this message…"). So the prompt says up
///     front that it is RE-VOICING a message, not performing a task, and bans
///     intent sentences by example.
///  2. **Wrong language** — the headline drifts away from the source language,
///     usually riding the meta leak. The language rule is stated FIRST and
///     again AFTER the content, and names the headline specifically, because
///     the headline is the half that drifts.
///
/// Pure, so the wording can be tested without a model.
String panelSummaryPrompt(String said, String ask) {
  final askBlock = ask.isEmpty
      ? ''
      : "The user's request this turn was: «$ask». Use this request as the "
            "turn's language signal and context, but take all facts from the "
            'assistant message below. Your recap MUST lead with the DIRECT '
            'answer to that exact request — the specific fact, number, decision '
            'or result they asked for (asked a price → the price; asked yes/no '
            '→ the verdict; asked "how" → the key step), taken from the '
            "assistant's message below, then a few words of context. Do NOT "
            'lead with a generic characterization of the topic, and do NOT '
            'invent anything not in the message.\n\n';

  return 'LANGUAGE RULE (most important): choose the output language ONLY from the '
      "user's request for this turn and the assistant message between the --- "
      'markers below. If both are in English, output English. If they use '
      'another language, output that language. If they mix languages, preserve '
      'that mix naturally. Never switch to a language that does not appear in '
      "the user's request or the assistant message. Ignore previous "
      'conversation, account locale, environment locale, and the language of '
      'these instructions.\n\n'
      '$askBlock'
      'Between the --- markers below is a message the assistant already sent to '
      'the user. Re-voice its CONTENT back to the user, in the FIRST PERSON as '
      'that same assistant (its own "I"). You are ONLY restating what the '
      'message says — you are NOT performing any task and NOT describing this '
      'summarizing job. NEVER write a meta or intent sentence such as "I need '
      'to…", "I will summarize/convert/translate…", "let me…", or "the message '
      'is about…". Output ONLY these two parts separated by a blank line, with '
      'no headings, labels or preamble:\n'
      'Part 1 (recap) — a NEWSPAPER HEADLINE for this turn: ONE punchy, '
      'self-contained line of at most $kPanelRecapMaxWords words. State the '
      'SINGLE most important thing the user needs from this turn — the direct '
      'answer, decision, result or recommendation to their request (what was '
      'said or done, NOT a plan of what you will do next, NOT a description of '
      'the topic) — and FRONT-LOAD it so the first few words alone carry the '
      'point (only the opening may be shown). Headline voice: active, specific, '
      'punchy; NO hedging or throat-clearing (never open with "I think…", "This '
      'is a close one…", "It is about…", "Regarding…") — conclusion first, then '
      'at most a few words of why; if the source hedges, still commit to its '
      'leaning up front. It MUST be COMPLETE within $kPanelRecapMaxWords words: '
      'never cut off mid-idea, never end on a connector/preposition/unfinished '
      'clause, and NEVER use "…", "..." or any ellipsis or trailing dots. If you '
      'would run long, TIGHTEN the wording into a shorter headline — do not '
      'truncate. Do NOT enumerate long lists — give the gist (use counts like '
      '"4 forwards" instead of naming everyone). PLAIN TEXT ONLY: no emoji, '
      'markdown, tables, bullets or URLs.\n'
      'Part 2 (after a blank line) — a fuller summary: present tense, condensed '
      'to the key points, markedly shorter than the original; scale to the '
      'source (a short message → a sentence or two, a long/detailed one → a '
      'short recap), never a full restatement, at most $kPanelSummaryMaxWords '
      'words. Here you MAY include the important specifics/lists that the recap '
      'omitted. Like the recap it MUST read as finished: end on a COMPLETE '
      'sentence, never mid-idea or on a dangling connector, and NEVER use "…", '
      '"..." or any ellipsis or trailing dots. If you would run long, drop the '
      'least important detail — do not truncate.\n'
      'For both parts, restate the substance itself; do NOT narrate the process '
      '(avoid "I wrote/did…").\n\n---\n$said\n\n---\n'
      'IMPORTANT: before you answer, re-check the user\'s request and source '
      'message. Write BOTH parts — INCLUDING the one-line recap — in their '
      'language and register. Do NOT translate or switch to any language absent '
      'from those two inputs. Keep technical terms, code, and product names '
      'as-is.';
}

/// Split the model's answer on the first blank line and cap each half
/// **independently**.
///
/// A shared budget would let a runaway headline eat the summary's quota. With
/// no blank line the whole answer is taken as the headline — a model that gave
/// one line gave a headline, and inventing a body from it would be inventing.
PanelTurnSummary splitPanelSummary(String raw) {
  final trimmed = raw.trim();
  final split = trimmed.indexOf('\n\n');
  final head = (split >= 0 ? trimmed.substring(0, split) : trimmed).trim();
  final body = (split >= 0 ? trimmed.substring(split + 2) : '').trim();
  return PanelTurnSummary(
    recap: capPanelRecap(head, kPanelRecapMaxWords),
    summary: capPanelSentence(body, kPanelSummaryMaxWords),
  );
}

/// Trailing connectors a headline must never END on.
/// A hard cut landing here leaves it dangling — "…2-1, thanks to".
///
/// Prefixed with a separator class rather than `\b`, because **Dart's `\b` is
/// ASCII-only** — exactly as JavaScript's is — so it cannot see the boundary of
/// a word ending in an accented vowel, and the dangle survives. The list is
/// English, so a headline written in another language can still end on one of
/// its own connectors.
final RegExp _danglingTail = RegExp(
  r'[\s,;:–—-]+(and|or|but|with|because|since|so|to|for|of|in|on|'
  r'at|the|a|an)[\s,;:–—-]*$',
  caseSensitive: false,
);

final RegExp _ellipsis = RegExp(r'…|\.{2,}');
final RegExp _whitespace = RegExp(r'\s+');
final RegExp _sentenceEnd = RegExp(r'[.!?。！？]$', unicode: true);

/// Cap a headline: one line, at most [max] words, and **never an ellipsis**.
///
/// The model is told to write a complete headline within budget; this is the
/// hard guard for when it overshoots. It cuts at the last clause boundary in
/// the kept portion and strips any dangling connector, so the line still ends
/// on a complete point — but it does NOT append "…", because a headline reads
/// as finished, not as truncated.
String capPanelRecap(String text, int max) {
  var t = text.replaceAll(_ellipsis, ' ').replaceAll(_whitespace, ' ').trim();
  final words = t.split(' ').where((w) => w.isNotEmpty).toList();
  if (words.length > max) {
    var head = words.take(max).join(' ');
    // Prefer ending at the last clause boundary: keeps most of the sentence and
    // drops the half-written trailing clause, rather than cutting on whichever
    // word the budget happened to land on.
    final boundary = [
      head.lastIndexOf(','),
      head.lastIndexOf(';'),
      head.lastIndexOf('. '),
    ].reduce((a, b) => a > b ? a : b);
    if (boundary > head.length * 0.5) head = head.substring(0, boundary);
    t = head;
  }
  return _stripDangling(t);
}

/// Cap a paragraph the way the headline is capped: no ellipsis, always a
/// finished sentence.
///
/// Prefers to cut at the last sentence terminator inside the budget — which
/// works for any language that ends a sentence with one — and only falls back
/// to the clause/connector trim when there is none.
String capPanelSentence(String text, int max) {
  var t = text.replaceAll(_ellipsis, ' ').replaceAll(_whitespace, ' ').trim();
  final words = t.split(' ').where((w) => w.isNotEmpty).toList();
  if (words.length > max) {
    final head = words.take(max).join(' ');
    final ends = RegExp(r'[.!?。！？]', unicode: true).allMatches(head).toList();
    final last = ends.isEmpty ? null : ends.last;
    t = (last != null && last.start > head.length * 0.4)
        ? head.substring(0, last.start + 1)
        : head;
  }
  return _sentenceEnd.hasMatch(t) ? t : _stripDangling(t);
}

String _stripDangling(String text) {
  var t = text;
  String previous;
  do {
    previous = t;
    t = t
        .replaceAll(_danglingTail, '')
        .replaceAll(RegExp(r'[\s,;:–—-]+$'), '')
        .trim();
  } while (t != previous);
  return t;
}

/// Whether [out] reads as a **different language** than [source].
///
/// Deliberately not a language identifier. Naming languages means a
/// hand-maintained word list per language and a check that only ever runs one
/// way — it catches "should be English, came back Vietnamese" and never the
/// reverse. Comparing which writing systems a text uses, and how accented its
/// Latin part is, catches "answered in a different language" for any pair, with
/// nothing to maintain.
///
/// Thresholds are loose on purpose: quoting a product name or a code identifier
/// in another script must not trip it.
bool panelLanguageDrifted(String source, String out) {
  final a = _scriptProfile(source);
  final b = _scriptProfile(out);
  // Too little signal to judge.
  if (a.letters < 12 || b.letters < 12) return false;
  for (final name in _scripts.keys) {
    if (name == 'Latin') continue;
    final sa = a.shares[name] ?? 0;
    final sb = b.shares[name] ?? 0;
    // The source is written in it and the output is not, or the output switched
    // into a script the source never used.
    if (sa >= 0.15 && sb <= 0.02) return true;
    if (sb >= 0.15 && sa <= 0.02) return true;
  }
  final latinBoth =
      (a.shares['Latin'] ?? 0) >= 0.5 && (b.shares['Latin'] ?? 0) >= 0.5;
  if (latinBoth && a.accented >= 0.08 && b.accented <= 0.02) return true;
  if (latinBoth && b.accented >= 0.08 && a.accented <= 0.02) return true;
  return false;
}

final Map<String, RegExp> _scripts = {
  'Han': RegExp(r'\p{Script=Han}', unicode: true),
  'Hiragana': RegExp(r'\p{Script=Hiragana}', unicode: true),
  'Katakana': RegExp(r'\p{Script=Katakana}', unicode: true),
  'Hangul': RegExp(r'\p{Script=Hangul}', unicode: true),
  'Cyrillic': RegExp(r'\p{Script=Cyrillic}', unicode: true),
  'Arabic': RegExp(r'\p{Script=Arabic}', unicode: true),
  'Hebrew': RegExp(r'\p{Script=Hebrew}', unicode: true),
  'Thai': RegExp(r'\p{Script=Thai}', unicode: true),
  'Devanagari': RegExp(r'\p{Script=Devanagari}', unicode: true),
  'Greek': RegExp(r'\p{Script=Greek}', unicode: true),
  'Latin': RegExp(r'\p{Script=Latin}', unicode: true),
};

final RegExp _letter = RegExp(r'\p{L}', unicode: true);

class _ScriptProfile {
  const _ScriptProfile(this.shares, this.accented, this.letters);

  /// Share of letters per writing system, e.g. `{Latin: 0.9, Han: 0.1}`.
  final Map<String, double> shares;

  /// Share of Latin letters carrying a diacritic — what separates Vietnamese,
  /// Polish and Turkish from English.
  ///
  /// Measured as "Latin and outside ASCII" rather than by decomposing to
  /// combining marks: Dart has no Unicode normalisation in its core library,
  /// and for this question the two answers agree — every accented Latin letter
  /// is non-ASCII, and no unaccented English letter is.
  final double accented;

  final int letters;
}

_ScriptProfile _scriptProfile(String text) {
  final counts = <String, int>{};
  var letters = 0;
  var accented = 0;
  for (final char in text.split('')) {
    if (!_letter.hasMatch(char)) continue;
    final name = _scripts.entries
        .where((e) => e.value.hasMatch(char))
        .map((e) => e.key)
        .firstOrNull;
    if (name == null) continue;
    letters++;
    counts[name] = (counts[name] ?? 0) + 1;
    if (name == 'Latin' && char.codeUnitAt(0) > 0x7F) accented++;
  }
  final shares = <String, double>{};
  if (letters > 0) {
    for (final entry in counts.entries) {
      shares[entry.key] = entry.value / letters;
    }
  }
  final latin = counts['Latin'] ?? 0;
  return _ScriptProfile(shares, latin > 0 ? accented / latin : 0, letters);
}
