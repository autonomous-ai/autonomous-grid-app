import '../../../core/app_environment.dart';
import 'agent_catalog.dart';

/// Whether this build offers **Auto** at all.
///
/// Developer-only, like the Grids and Debug screens (`ShellSection.devOnly`):
/// picking the assistant is a choice an end user makes once and recognises
/// afterwards — the reply's footer names who answered — while Auto makes it a
/// different one per question, and the app then has an assistant whose name
/// changes under them for reasons only the router knows. It also spends a
/// round-trip to the grid's model in front of every turn before the turn starts.
///
/// Gating it here rather than only hiding the row is what keeps a *stored* Auto
/// choice from going on routing in a shipped build: see
/// `isAutoAgentChosenForProjectProvider`, which reads this, and
/// `chatAgentForProjectProvider`, which resolves the unknown id to a real agent.
/// The choice itself is left on disk untouched, so a developer build gives it
/// straight back.
bool get autoAgentIsOffered => AppEnvironment.isDeveloperMode;

/// The sentinel id stored as the chat agent when the user picks **Auto** — the
/// meta-agent that lets the grid choose, per question, which installed
/// assistant answers.
///
/// A string sentinel rather than an [AgentTool] value on purpose: Auto is not a
/// harness that can answer anything itself, it is a *choice about* the real
/// four. Mirrors how `kAutoModelId` ('auto') names the model auto-router
/// without being a model.
const String kAutoAgentId = 'auto';

/// Whether [id] is the Auto choice — the stored `chatAgent` string, which is a
/// real [AgentTool] id in every other case.
bool isAutoAgentId(String? id) => id == kAutoAgentId;

/// The one-line summary the Auto picker shows for the Auto row.
const String kAutoAgentTagline =
    'Picks the best installed assistant for each question.';

/// The messages sent to the grid's auto model to pick an assistant for
/// [question] from [candidates].
///
/// Pure, so `test/agents/` can pin the exact prompt: this is the one place the
/// router's *judgement* is shaped, and a prompt that drifts is a routing bug
/// that never throws. The reply is constrained to a bare id — parsing a
/// sentence back into an agent is far less reliable than asking for the id and
/// nothing else, and [parseRoutedAgent] still defends against a model that
/// answers with prose anyway.
List<Map<String, dynamic>> buildRouterMessages(
  String question,
  List<AgentTool> candidates,
) {
  final catalogue = [
    for (final agent in candidates) '- ${agent.id}: ${agent.strengths}',
  ].join('\n');
  final ids = candidates.map((a) => a.id).join(', ');
  return [
    {
      'role': 'system',
      'content':
          'You route a user\'s message to the coding/chat assistant best '
          'suited to it. Here are the available assistants and what each is '
          'best at:\n\n$catalogue\n\n'
          'Reply with ONLY the id of the single best assistant for the '
          'message — one of: $ids. No punctuation, no explanation, just the id.',
    },
    {'role': 'user', 'content': question},
  ];
}

/// The agent named by a router [reply], constrained to [candidates] — or null
/// when the reply names none of them.
///
/// Tolerant of a model that ignores the "id only" instruction: it lower-cases,
/// and matches an id as a whole word anywhere in the reply, so "I'd use codex."
/// still resolves. Longer ids are tried first so `codex-cli` can't be shadowed
/// by `codex` (not a candidate today, but the rule costs nothing and the bug it
/// prevents is silent). A reply that names two candidates resolves to neither —
/// an ambiguous answer is no answer, and the caller falls back rather than
/// guessing which the model meant.
AgentTool? parseRoutedAgent(String reply, List<AgentTool> candidates) {
  final text = reply.toLowerCase();
  final byLength = [...candidates]
    ..sort((a, b) => b.id.length.compareTo(a.id.length));
  AgentTool? found;
  for (final agent in byLength) {
    if (!_containsWord(text, agent.id)) continue;
    // A second, different candidate named in the same reply makes it ambiguous.
    if (found != null && found != agent) return null;
    found = agent;
  }
  return found;
}

/// Whether [text] contains [word] bounded by non-alphanumerics (or the ends),
/// so `codex` matches in "use codex" but not inside "codexish".
bool _containsWord(String text, String word) {
  var from = 0;
  while (true) {
    final at = text.indexOf(word, from);
    if (at < 0) return false;
    final before = at == 0 ? '' : text[at - 1];
    final afterAt = at + word.length;
    final after = afterAt >= text.length ? '' : text[afterAt];
    if (!_isWordChar(before) && !_isWordChar(after)) return true;
    from = at + 1;
  }
}

bool _isWordChar(String ch) =>
    ch.isNotEmpty && RegExp(r'[a-z0-9]').hasMatch(ch);

/// A keyword-only guess at the right agent, for when the grid can't be asked
/// (offline, no model, the call failed or came back unusable).
///
/// Deliberately simple and conservative: it leans coding work toward a coding
/// agent when one is available, and otherwise falls back to the first
/// candidate — which is the general-purpose one (Hermes) in the catalogue's own
/// order. It is a safety net, not the main path; the grid classifier is.
AgentTool heuristicRoute(String question, List<AgentTool> candidates) {
  if (candidates.length == 1) return candidates.first;
  final looksLikeCode = _kCodeHint.hasMatch(question.toLowerCase());
  if (looksLikeCode) {
    for (final preferred in const [AgentTool.claude, AgentTool.codex]) {
      if (candidates.contains(preferred)) return preferred;
    }
  }
  return candidates.first;
}

/// One message reads as coding work when it contains any of these as a **whole
/// word** — bounded, so `api` doesn't fire on "capital" and `class` doesn't fire
/// on "classifier". The trailing `\w*` on a few lets a stem catch its family
/// ("refactor" → "refactoring", "debug" → "debugging") without matching an
/// unrelated word that merely starts the same way.
final RegExp _kCodeHint = RegExp(
  r'\b('
  r'code|coding|bug|error|stack trace|compile|refactor\w*|function|class|'
  r'variable|repository|repo|git|commit|test|tests|api|endpoint|build|deploy|'
  r'script|debug\w*|implement\w*|typescript|javascript|python|dart|flutter|'
  r'react|sql'
  r')\b',
);
