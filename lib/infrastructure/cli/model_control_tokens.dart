/// The chat-template markers a model is never supposed to say out loud, and
/// what an answer carrying one is worth after it.
///
/// A served model is prompted with a template — ChatML, Llama, DeepSeek — whose
/// turn boundaries are single tokens: `<|im_start|>`, `<|im_end|>`,
/// `<|endoftext|>`. The server is meant to stop at the first one and strip the
/// rest; when it doesn't, they arrive as ordinary text and the app draws them,
/// which is how a reply came to end in
/// `(chờ risposta)<|endoftext|><|im_start|><|im_start|><|im_start|>user`.
///
/// Measured on this machine, 2026-08-18: `~/.grid/app/chats/1787050443254773.json`,
/// a turn served by `DeepSeek-V4-Flash-0731` over the grid. The tokens are in a
/// timeline passage, so they were saved as well as shown.
library;

/// Any chat-template token: a name between `<|` and `|>`.
///
/// Deliberately not a list of known names. Every family spells its own
/// differently (`<|eot_id|>`, `<|end▁of▁sentence|>`, `<|end_of_turn|>`) and a
/// list would silently pass whichever one the next engine on the grid uses.
/// Nothing a person asks for renders as `<|…|>`, so the shape is enough.
final _controlToken = RegExp(r'<\|[^|>\n]{0,40}\|>');

/// [text] cut at the first chat-template token in it.
///
/// **Cut, not filtered.** A model that emits a turn boundary mid-answer has
/// stopped answering: what follows is it playing out the rest of the
/// conversation by itself — the fabricated `user` turn above is exactly that.
/// Dropping the markers and keeping the words after them would leave the model's
/// invention of what the user says next sitting in the reply as if the agent had
/// written it.
///
/// The trade-off, stated plainly: an answer that legitimately quotes one of
/// these tokens — someone asking what `<|im_start|>` means — is cut short. That
/// is a rarer turn than a served model overrunning its stop token, and it fails
/// visibly (a short answer) rather than deceptively (a fabricated dialogue).
///
/// Returns [text] unchanged when there is nothing to cut, so the ordinary answer
/// is not rebuilt on its way to the screen.
String stripControlTokens(String text) {
  // A plain scan first: this runs on every streamed delta, and the regex is only
  // worth entering for the handful of turns that carry a marker at all.
  if (!text.contains('<|')) return text;
  final cut = _controlToken.firstMatch(text);
  if (cut == null) return text;
  return text.substring(0, cut.start).trimRight();
}
