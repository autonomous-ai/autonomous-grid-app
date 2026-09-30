/// What an agent's work looks like on the wire to a phone: the steps it runs
/// and the questions it stops to ask.
///
/// Here rather than in either app because both have to agree on it and they
/// ship separately — the desktop writes these, the phone reads them, and a
/// field renamed on one side alone would be a phone showing blank rows.
library;

/// How many of a live turn's steps a `chats.head` answer carries — the newest.
///
/// A head is asked for every 700ms while an agent works, and one overnight
/// turn on this machine ran 1,689 steps. The phone shows the tail anyway;
/// [MobileLiveTurn.stepCount] says how many came before it.
const int kMobileLiveSteps = 30;

/// How many of a finished turn's steps a transcript page carries per turn.
const int kMobileStepsPerTurn = 60;

/// How long a step's label may be when it reaches a phone.
///
/// A thinking step's label is the model's whole reasoning — thousands of
/// characters — and a row on a phone shows one or two lines of it.
const int kMobileStepLabelLimit = 240;

/// How much of an edit a permission question shows.
const int kMobilePermissionPreviewLimit = 2000;

/// What kind of step: the icon the phone draws for it.
enum MobileStepKind { command, web, tool, thinking }

/// Where a step has got to.
enum MobileStepStatus { running, done, failed, unknown }

/// One step an agent ran, as much as a phone row needs.
///
/// No request and no result: those are what the agent read and what came
/// back — a file's contents, a command's output — and they stay on the
/// computer. The label says what the step was, which is what a person
/// following along from a phone is asking.
class MobileStep {
  const MobileStep({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    this.tool,
    this.nested = false,
  });

  /// Stable across the step's life, so a row that finishes updates in place.
  final String id;

  final MobileStepKind kind;

  /// What it was, in the agent's words — capped at [kMobileStepLabelLimit].
  final String label;

  final MobileStepStatus status;

  /// The tool's own name (`Bash`, `Read`), when the agent said.
  final String? tool;

  /// Whether a sub-agent ran it rather than the agent itself.
  final bool nested;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'label': capMobileText(label, kMobileStepLabelLimit),
    'status': status.name,
    if (tool != null) 'tool': tool,
    if (nested) 'nested': true,
  };

  /// The step [value] describes, or null when it is not one. Unknown kinds and
  /// statuses read as the plainest ones, so a newer desktop's step still draws.
  static MobileStep? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final label = value['label'];
    if (id is! String || label is! String) return null;
    final tool = value['tool'];
    return MobileStep(
      id: id,
      kind: _byName(MobileStepKind.values, value['kind'], MobileStepKind.tool),
      label: label,
      status: _byName(
        MobileStepStatus.values,
        value['status'],
        MobileStepStatus.unknown,
      ),
      tool: tool is String ? tool : null,
      nested: value['nested'] == true,
    );
  }
}

/// What the agent wants permission for.
enum MobilePermissionKind { command, edit, other }

/// What the person answered.
enum MobilePermissionChoice { allowOnce, allowForChat, refuse }

/// A question the agent has stopped to ask, and is waiting on.
///
/// The phone is shown what the computer's own card shows, minus the file's
/// current contents: the command, or the file and what it would become.
class MobilePermission {
  const MobilePermission({
    required this.id,
    required this.kind,
    required this.summary,
    required this.canAllowForChat,
    this.detail,
    this.preview,
  });

  /// Which question — echoed back with the answer, so a tap on a card that has
  /// since been replaced by the next question does not answer that one.
  final String id;

  final MobilePermissionKind kind;

  /// One line saying what it is for.
  final String summary;

  /// The command line, or the file's path.
  final String? detail;

  /// What the file would contain, capped at [kMobilePermissionPreviewLimit].
  final String? preview;

  /// Whether "allow for this chat" was offered — it is not, for file edits.
  final bool canAllowForChat;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'summary': summary,
    if (detail != null) 'detail': detail,
    if (preview != null)
      'preview': capMobileText(preview!, kMobilePermissionPreviewLimit),
    'canAllowForChat': canAllowForChat,
  };

  static MobilePermission? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final summary = value['summary'];
    if (id is! String || summary is! String) return null;
    final detail = value['detail'];
    final preview = value['preview'];
    return MobilePermission(
      id: id,
      kind: _byName(
        MobilePermissionKind.values,
        value['kind'],
        MobilePermissionKind.other,
      ),
      summary: summary,
      detail: detail is String ? detail : null,
      preview: preview is String ? preview : null,
      canAllowForChat: value['canAllowForChat'] == true,
    );
  }
}

/// What a chat is doing right now — the `chats.head` answer.
class MobileLiveTurn {
  const MobileLiveTurn({
    required this.total,
    required this.busy,
    this.streaming = '',
    this.steps = const [],
    this.stepCount = 0,
    this.permission,
  });

  /// How many turns the chat has on disk.
  final int total;

  /// Whether an answer is being written.
  final bool busy;

  /// The answer as far as it has got.
  final String streaming;

  /// The newest [kMobileLiveSteps] steps of the running turn.
  final List<MobileStep> steps;

  /// How many steps the running turn has run in all.
  final int stepCount;

  /// The question the agent is waiting on, if it is.
  final MobilePermission? permission;

  Map<String, Object?> toJson(String id) => {
    'id': id,
    'total': total,
    'busy': busy,
    // Only when there is something: an empty key on every poll is bytes spent
    // to say nothing, and this is asked for every second or so.
    if (streaming.isNotEmpty) 'streaming': streaming,
    if (steps.isNotEmpty) 'steps': [for (final step in steps) step.toJson()],
    if (stepCount > 0) 'stepCount': stepCount,
    if (permission != null) 'permission': permission!.toJson(),
  };

  /// The head [value] describes, or null without a turn count. An older
  /// desktop sends no steps and no permission, which reads as none.
  static MobileLiveTurn? fromJson(Map<String, Object?> value) {
    final total = value['total'];
    if (total is! int) return null;
    final steps = mobileStepsFromJson(value['steps']);
    final count = value['stepCount'];
    return MobileLiveTurn(
      total: total,
      busy: value['busy'] == true,
      streaming: '${value['streaming'] ?? ''}',
      steps: steps,
      stepCount: count is int ? count : steps.length,
      permission: MobilePermission.fromJson(value['permission']),
    );
  }
}

/// The steps in [value], skipping anything that is not one.
List<MobileStep> mobileStepsFromJson(Object? value) => [
  for (final item in value is List ? value : const [])
    ?MobileStep.fromJson(item),
];

/// The newest [limit] of [steps] — what a phone is sent of a long turn.
List<T> newestOf<T>(List<T> steps, int limit) =>
    steps.length <= limit ? steps : steps.sublist(steps.length - limit);

/// [text] cut to [limit] characters, marked with an ellipsis when it was.
///
/// Never splits a surrogate pair: half an emoji is a character the phone's
/// text engine draws as a box.
String capMobileText(String text, int limit) {
  if (text.length <= limit) return text;
  var end = limit - 1;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return '${text.substring(0, end)}…';
}

T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
