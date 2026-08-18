/// One decision an agent stopped to ask about, and the answers it offered.
///
/// Claude Code's `AskUserQuestion` tool. In its own terminal the CLI draws the
/// picker itself; under `claude -p` — which is how this app runs every turn —
/// there is nobody to draw it, so the CLI answers the call itself with *"The
/// user did not answer the questions."* and the model carries on guessing.
/// Measured on 2026-08-18 in a workspace session, which is why this exists: the
/// app reads the question out of the call and asks it in the chat, and the
/// user's pick goes back as the next message.
class AgentQuestion {
  const AgentQuestion({
    required this.question,
    required this.header,
    required this.options,
    required this.multiSelect,
  });

  /// The question in full, as the agent phrased it.
  final String question;

  /// The agent's own short name for the decision ("Frequency", "Scope") — what
  /// the card labels the group with, and what the answer echoes back so a
  /// multi-question reply can't be read against the wrong question.
  final String header;

  /// The answers offered, in the agent's order. Never empty — a question with
  /// nothing to pick is dropped by [parseAgentQuestions].
  final List<AgentQuestionOption> options;

  /// Whether more than one answer may be picked.
  final bool multiSelect;

  /// What the answer names this question — the short header when the agent gave
  /// one, else the question itself.
  String get label => header.isEmpty ? question : header;
}

/// One answer on offer, and what picking it means.
class AgentQuestionOption {
  const AgentQuestionOption({required this.label, required this.description});

  final String label;

  /// The trade-off behind the label. May be empty; the card shows it under the
  /// label, so an option that explains itself needs nothing here.
  final String description;
}

/// Reads the `questions` array of an `AskUserQuestion` call.
///
/// Lenient in the same way the rest of this layer is: anything that isn't a
/// usable question is dropped rather than rendered as a broken row. A question
/// with no text, or with no option to pick, cannot be answered by a card, and
/// the caller falls back to showing the raw call when nothing survives.
List<AgentQuestion> parseAgentQuestions(Object? raw) {
  if (raw is! List) return const [];
  final out = <AgentQuestion>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final question = '${entry['question'] ?? ''}'.trim();
    final header = '${entry['header'] ?? ''}'.trim();
    if (question.isEmpty && header.isEmpty) continue;
    final options = _parseOptions(entry['options']);
    if (options.isEmpty) continue;
    out.add(
      AgentQuestion(
        question: question.isEmpty ? header : question,
        header: header,
        options: options,
        multiSelect: entry['multiSelect'] == true,
      ),
    );
  }
  return List.unmodifiable(out);
}

List<AgentQuestionOption> _parseOptions(Object? raw) {
  if (raw is! List) return const [];
  final out = <AgentQuestionOption>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final label = '${entry['label'] ?? ''}'.trim();
    if (label.isEmpty) continue;
    out.add(
      AgentQuestionOption(
        label: label,
        description: '${entry['description'] ?? ''}'.trim(),
      ),
    );
  }
  return List.unmodifiable(out);
}

/// The message that carries [picks] back to the agent, keyed by each question's
/// index in [questions].
///
/// One line per question, `label: answer`, because the agent asks up to four at
/// once and a bare list of answers cannot be matched to them. A question nobody
/// picked is left out rather than answered with a blank — the agent asked, and
/// silence on one of four is a truthful answer to give. Returns an empty string
/// when nothing was picked at all, which is the caller's signal not to send.
String answerToQuestions(
  List<AgentQuestion> questions,
  Map<int, Set<String>> picks,
) {
  final lines = <String>[];
  for (var i = 0; i < questions.length; i++) {
    final chosen = picks[i];
    if (chosen == null || chosen.isEmpty) continue;
    // The agent's own order, not the order they were tapped in — a multi-select
    // answer should read the way the question listed it.
    final answer = [
      for (final option in questions[i].options)
        if (chosen.contains(option.label)) option.label,
    ].join(', ');
    if (answer.isEmpty) continue;
    lines.add('${questions[i].label}: $answer');
  }
  return lines.join('\n');
}
