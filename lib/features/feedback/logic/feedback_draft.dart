import 'feedback_diagnostics.dart';

/// What a piece of feedback is *about*.
///
/// Three kinds, not ten: the person writing knows instantly which one they are,
/// and each lands with a different reader — a broken thing is triage, an idea is
/// roadmap. A longer list would make the first decision harder than the writing.
enum FeedbackKind {
  bug(
    id: 'bug',
    label: 'Something broke',
    hint: 'What were you doing, and what happened instead?',
  ),
  idea(id: 'idea', label: 'An idea', hint: 'What would you like Grid to do?'),
  other(
    id: 'other',
    label: 'Something else',
    hint: "Anything you'd like us to know.",
  );

  const FeedbackKind({
    required this.id,
    required this.label,
    required this.hint,
  });

  /// The value sent to the server — stable, unlike [label].
  final String id;

  /// The segment's caption.
  final String label;

  /// The message field's placeholder for this kind. It asks the question whose
  /// answer we actually need, so a bug report arrives with the steps in it
  /// rather than "it doesn't work".
  final String hint;
}

/// Shortest message worth sending.
///
/// Not a quality bar — a guard against the accidental submit ("hi", a stray
/// keystroke, an empty form). Anything a person meant to write clears it.
const int kFeedbackMinLength = 10;

/// Longest message the form accepts, so a pasted log can't become the payload.
const int kFeedbackMaxLength = 4000;

/// One piece of feedback as the form holds it, before it becomes a request.
///
/// Immutable and free of IO so the rules below — what is sendable, what is
/// actually transmitted — can be read (and reasoned about) in one place instead
/// of being spread through the dialog's state.
class FeedbackDraft {
  const FeedbackDraft({
    required this.kind,
    required this.message,
    this.email,
    this.diagnostics,
  });

  final FeedbackKind kind;
  final String message;

  /// Where a reply would go — the signed-in account's address. Null when the
  /// app has no email for this user, in which case the feedback is anonymous
  /// and the form says so rather than implying someone can write back.
  final String? email;

  /// The attached snapshot, or null when the user switched it off. Null means
  /// *nothing* about the machine is sent — not even the app version, which is
  /// part of this object rather than a field of its own precisely so the
  /// switch can't half-apply.
  final FeedbackDiagnostics? diagnostics;

  String get _trimmed => message.trim();

  /// Whether the Send button does anything. Deliberately loose — an empty form
  /// is the only state where pressing Send would be meaningless, and
  /// [problem] explains anything else *after* the press, where the explanation
  /// is asked for rather than pre-emptive.
  bool get hasMessage => _trimmed.isNotEmpty;

  /// Why this can't be sent, in the words shown under the field — or null when
  /// it can. Checked on submit, not on every keystroke: a field that reddens
  /// while you are still typing the first word is a field people fight.
  String? get problem {
    if (_trimmed.length < kFeedbackMinLength) {
      return 'Add a little more detail — one sentence is enough.';
    }
    if (_trimmed.length > kFeedbackMaxLength) {
      return "That's longer than we can send. Trim it to "
          '$kFeedbackMaxLength characters.';
    }
    return null;
  }

  FeedbackDraft copyWith({
    FeedbackKind? kind,
    String? message,
    FeedbackDiagnostics? diagnostics,
    bool clearDiagnostics = false,
  }) => FeedbackDraft(
    kind: kind ?? this.kind,
    message: message ?? this.message,
    email: email,
    // `?? this.x` cannot express "unset" — the flag is what lets the switch
    // turn diagnostics back off. Same trap `Conversation.archivedAt` hit.
    diagnostics: clearDiagnostics ? null : (diagnostics ?? this.diagnostics),
  );
}

/// The request body for one [draft] — the single definition of what leaves this
/// computer, shared by the live send and the copy saved when that send fails,
/// so the two can never describe the same feedback differently.
///
/// [now] is passed in rather than read here so the payload is a pure function of
/// its inputs.
Map<String, dynamic> feedbackPayload(
  FeedbackDraft draft, {
  required DateTime now,
}) => {
  'kind': draft.kind.id,
  'message': draft.message.trim(),
  if (draft.email != null) 'email': draft.email,
  // Which surface it came from: the same control plane serves the CLI and the
  // website, and a bug in the desktop app reads differently from one in either.
  'source': 'desktop-app',
  'submitted_at': now.toUtc().toIso8601String(),
  if (draft.diagnostics != null) 'diagnostics': draft.diagnostics!.toJson(),
};
