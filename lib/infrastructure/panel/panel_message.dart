/// The vocabulary the Grid Panel and this app speak over USB.
///
/// Named in **this app's** nouns, not the reference device's: a `project` is
/// the working unit with a workspace, and an `agent` is the runtime that
/// answers in it. The device firmware this design borrows its layout from uses
/// those two words the other way round, and adopting its vocabulary would buy
/// a translation layer that never goes away.
///
/// Deliberately free of Flutter, like [PanelFrame] beneath it — the protocol is
/// checked by driving it against a real device from a scratch script.
library;

import 'dart:convert';

/// The message-layer version, sent in `hello` and answered in `welcome`.
///
/// Separate from the framing version on purpose: adding a message is a change
/// here, while changing the envelope is a change there, and conflating them
/// forces a firmware reflash for what is only a new field.
const int kPanelProtocolVersion = 1;

/// How often the app says it is still here.
///
/// Over a cable there is no connection to lose: the app quitting and the app
/// having nothing to say are the same silence. The panel declares the app gone
/// after 15 s without a message of any kind, so this has to be comfortably
/// under a third of that — two pings may be lost to a busy moment and the link
/// still reads as alive.
const Duration kPanelHeartbeat = Duration(seconds: 5);

/// A message from the panel.
///
/// Sealed so the app's handler is exhaustive — except for [PanelUnknown],
/// which exists precisely so a newer firmware cannot make the link look dead.
sealed class PanelInbound {
  const PanelInbound();

  /// Parse one decoded JSON payload.
  ///
  /// Never throws: this arrives from a cable. A message that cannot be read is
  /// reported as [PanelMalformed] so the caller can count it, rather than
  /// taking down the link that delivered it.
  static PanelInbound parse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      return PanelMalformed(json, e.message);
    }
    if (decoded is! Map<String, Object?>) {
      return PanelMalformed(json, 'not a JSON object');
    }
    final type = decoded['t'];
    if (type is! String) return PanelMalformed(json, 'missing "t"');

    return switch (type) {
      'hello' => PanelHello(
        firmware: _str(decoded['fw']) ?? '',
        protocol: _int(decoded['proto']) ?? 0,
        mac: _str(decoded['mac']) ?? '',
      ),
      'projects.list' => const PanelProjectsRequested(),
      'turn.send' => PanelTurnRequested(
        projectId: _str(decoded['projectId']) ?? '',
        text: _str(decoded['text']) ?? '',
      ),
      'turn.stop' => PanelStopRequested(
        projectId: _str(decoded['projectId']) ?? '',
      ),
      'answer' => PanelAnswered(
        projectId: _str(decoded['projectId']) ?? '',
        id: _str(decoded['id']) ?? '',
        optionId: _str(decoded['optionId']) ?? '',
      ),
      'voice.begin' => PanelVoiceBegin(
        projectId: _str(decoded['projectId']),
        command: PanelVoiceCommand.of(_str(decoded['cmd'])),
      ),
      'voice.end' => const PanelVoiceEnd(),
      'voice.confirm' => PanelVoiceConfirm(
        routeId: _str(decoded['routeId']) ?? '',
        projectId: _str(decoded['projectId']) ?? '',
      ),
      'fw.accept' => const PanelFirmwareAccepted(),
      'fw.progress' => PanelFirmwareProgress(
        written: _int(decoded['written']) ?? 0,
      ),
      'fw.done' => const PanelFirmwareDone(),
      'fw.error' => PanelFirmwareFailed(_str(decoded['message']) ?? ''),
      _ => PanelUnknown(type, decoded),
    };
  }

  static String? _str(Object? v) => v is String ? v : null;
  static int? _int(Object? v) => v is int ? v : null;
}

/// The panel introducing itself, first thing after the port opens.
class PanelHello extends PanelInbound {
  const PanelHello({
    required this.firmware,
    required this.protocol,
    required this.mac,
  });

  final String firmware;
  final int protocol;

  /// The device's MAC, which macOS also exposes as the USB serial number —
  /// so the app can tell one panel from another before a byte is exchanged.
  final String mac;

  /// Whether this build can talk to that firmware.
  ///
  /// A mismatch is a real state to show, not an error to swallow: the app
  /// carries the firmware image and can offer to fix it.
  bool get isCompatible => protocol == kPanelProtocolVersion;
}

/// "Send me the project list."
class PanelProjectsRequested extends PanelInbound {
  const PanelProjectsRequested();
}

/// The user spoke or typed a turn on the panel.
class PanelTurnRequested extends PanelInbound {
  const PanelTurnRequested({required this.projectId, required this.text});

  final String projectId;
  final String text;
}

/// The user pressed stop on the panel.
///
/// Carries the project because the panel can stop any of them, not just
/// whichever one the desktop happens to have open.
class PanelStopRequested extends PanelInbound {
  const PanelStopRequested({required this.projectId});

  final String projectId;
}

/// The user answered a `question` on the panel.
///
/// [id] is the app's own handle for the request, echoed back unchanged — the
/// panel never looks inside it. [optionId] is one of the options that question
/// was sent with; the two surfaces race by design, so an answer naming a
/// request the app has already settled is dropped rather than reported.
class PanelAnswered extends PanelInbound {
  const PanelAnswered({
    required this.projectId,
    required this.id,
    required this.optionId,
  });

  final String projectId;
  final String id;
  final String optionId;
}

/// Which pill on the panel's action bar started this voice turn.
///
/// The panel draws three — Voice, Goal, Loop — and the two modifiers say what
/// *kind* of thing the next sentence is, not where it goes. They travel as a
/// prefix on the transcript rather than as a flag, because that is the only
/// place this app has to put them: a turn is a message, and `/goal` is a
/// message that begins with `/goal`.
///
/// **TODO(BE): the grid CLI has no `/goal` or `/loop`.** Searched across `lib/`
/// on 2026-08-16 and neither string appears anywhere. So a turn started from
/// those two pills most likely reaches the agent with a literal `/goal ` in
/// front of it and is read as words. The pills are drawn from the reference
/// device's design and were kept deliberately; this is the note that says what
/// pressing one currently does, so the next person does not have to find out by
/// pressing it.
enum PanelVoiceCommand {
  none(''),
  goal('/goal '),
  loop('/loop ');

  const PanelVoiceCommand(this.prefix);

  /// What goes in front of the transcript. Empty for [none].
  final String prefix;

  /// Read a wire value. Anything unrecognised — including an absent key, which
  /// arrives here as an empty string — is [none]: a newer panel offering a
  /// modifier this build does not know should still get its words through.
  static PanelVoiceCommand of(String? wire) => switch (wire) {
    'goal' => goal,
    'loop' => loop,
    _ => none,
  };
}

/// The user started speaking. PCM frames follow until [PanelVoiceEnd].
///
/// [projectId] is the tile they were looking at, or null from a screen that is
/// not a project — which is what makes routing the transcript a real question
/// rather than a lookup.
class PanelVoiceBegin extends PanelInbound {
  const PanelVoiceBegin({
    this.projectId,
    this.command = PanelVoiceCommand.none,
  });

  final String? projectId;

  /// The modifier pill that started it, if any.
  final PanelVoiceCommand command;
}

/// The user stopped speaking; every chunk has been sent.
class PanelVoiceEnd extends PanelInbound {
  const PanelVoiceEnd();
}

/// The user picked which project a transcript belonged to.
class PanelVoiceConfirm extends PanelInbound {
  const PanelVoiceConfirm({required this.routeId, required this.projectId});

  final String routeId;
  final String projectId;
}

/// The panel is ready to be written to. Firmware frames follow.
class PanelFirmwareAccepted extends PanelInbound {
  const PanelFirmwareAccepted();
}

/// How much of the image has reached flash.
class PanelFirmwareProgress extends PanelInbound {
  const PanelFirmwareProgress({required this.written});

  final int written;
}

/// The image is written and verified. The panel reboots into it.
class PanelFirmwareDone extends PanelInbound {
  const PanelFirmwareDone();
}

/// The update failed. The panel keeps running what it had.
class PanelFirmwareFailed extends PanelInbound {
  const PanelFirmwareFailed(this.message);

  final String message;
}

/// A well-formed message this build has no case for.
///
/// Kept rather than dropped so a newer firmware reads as a version mismatch
/// the app can report, instead of as a link that connects and then says
/// nothing.
class PanelUnknown extends PanelInbound {
  const PanelUnknown(this.type, this.payload);

  final String type;
  final Map<String, Object?> payload;
}

/// A message that could not be read at all.
class PanelMalformed extends PanelInbound {
  const PanelMalformed(this.raw, this.reason);

  final String raw;
  final String reason;
}

/// How the turn behind a tile's recap ended, which tints the recap card.
///
/// A recap is one line of ordinary prose whether the turn succeeded or died,
/// and a 466px tile has no other room to say which — so the fact travels
/// beside it rather than being read out of the words.
enum PanelRecapKind {
  /// The turn ended by itself.
  done,

  /// It ended on an error the app is showing in the window too.
  failed,

  /// It was cut off — Stop, a dead process, a broken stream — and left a step
  /// that never reported how it went.
  stopped,
}

/// One project as the panel shows it.
///
/// A thin projection on purpose: the panel draws a tile, so it needs a name, a
/// state and a line of recap — not the instructions, memory or path that make
/// up a project in the app.
class PanelProject {
  const PanelProject({
    required this.id,
    required this.name,
    this.agent,
    this.model,
    this.busy = false,
    this.recap = '',
    this.recapKind,
  });

  final String id;
  final String name;
  final String? agent;
  final String? model;
  final bool busy;
  final String recap;

  /// How the turn behind [recap] ended, or null when there is no recap to
  /// tint. Never sent for a project nobody has talked in yet: a kind with no
  /// line under it is a colour with nothing to colour.
  final PanelRecapKind? recapKind;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (agent != null) 'agent': agent,
    if (model != null) 'model': model,
    'busy': busy,
    if (recap.isNotEmpty) 'recap': recap,
    if (recap.isNotEmpty && recapKind != null) 'recapKind': recapKind!.name,
  };
}

/// One slice of a turn as the panel draws it — a passage the agent wrote, or a
/// step it ran, in the order it happened.
///
/// The panel's own projection of `TurnPart`, kept separate on purpose. The app's
/// type carries each step's request and result for the transcript; a 480px tile
/// draws a line of text and a spinner, and shipping the rest would spend the
/// frame budget on characters this screen cannot show.
class PanelTurnPart {
  /// A passage the agent wrote.
  const PanelTurnPart.text(String text)
    : label = text,
      status = null,
      kind = null,
      tool = null,
      arg = null,
      parent = null,
      t0 = null;

  /// A step the agent ran, with where it has got to.
  const PanelTurnPart.step({
    required this.label,
    required String this.status,
    required String this.kind,
    this.tool,
    this.arg,
    this.parent,
    this.t0,
  });

  /// The prose, or the step's one-line label.
  final String label;

  /// The step's status, or null when this is prose.
  final String? status;

  /// `command` · `web` · `tool` · `thinking` — what picks the row's colour on
  /// the device. Sent rather than left to be guessed from [tool], because a
  /// tool's name is the agent's own and every agent words it differently: a
  /// panel inferring a colour from it would draw the same kind of work in
  /// three colours depending on who ran it.
  final String? kind;

  /// The tool's own name (`Bash`, `Read`), when the transport carried one.
  final String? tool;

  /// What the agent asked the tool to do, clipped like the label.
  final String? arg;

  /// The id of the step that spawned this one — a sub-agent's work, drawn on
  /// its own band rather than the main one.
  final String? parent;

  /// Milliseconds from the start of the turn to the moment this step started.
  ///
  /// **Fixed while the step runs**, which is the whole point: the sender says
  /// nothing when nothing has changed, and an elapsed count would change every
  /// second and put the whole timeline back on the wire each tick. The device
  /// knows when `turn.started` arrived, so it can tick its own clock off a
  /// payload that is standing still.
  final int? t0;

  bool get isStep => status != null;

  Map<String, Object?> toJson() => status == null
      ? {'k': 't', 'text': label}
      : {
          'k': 's',
          'label': label,
          'status': status,
          if (tool != null) 'tool': tool,
          if (arg != null) 'arg': arg,
          'kind': kind,
          if (parent != null) 'parent': parent,
          if (t0 != null) 't0': t0,
        };
}

/// One step of the agent's plan as the panel draws it.
///
/// Rides the message rather than the parts: a plan is the state of an
/// intention, not a point in the story, and threading it through the timeline
/// would put a copy of the whole list beside every step that revised it.
class PanelTurnTodo {
  const PanelTurnTodo({required this.text, required this.status});

  final String text;

  /// The same vocabulary a step's status uses, so the device has one set of
  /// marks to draw rather than two.
  final String status;

  Map<String, Object?> toJson() => {'text': text, 'status': status};
}

/// One answer the user can give to a [PanelOutbound.question].
///
/// [id] is the agent's own option id, echoed back in `answer` unchanged — the
/// app looks it up rather than reading the label, which is only ever drawn.
class PanelQuestionOption {
  const PanelQuestionOption({required this.id, required this.label});

  final String id;
  final String label;

  Map<String, Object?> toJson() => {'id': id, 'label': label};
}

/// Messages this app sends to the panel.
///
/// Plain builders rather than a sealed family: the app is the only producer,
/// so a wrong one is a compile-time concern here, not a parsing concern there.
abstract final class PanelOutbound {
  /// Answer to [PanelHello]. Carries which machine the panel is looking at,
  /// which on this link is simply the computer it is plugged into.
  static String welcome({
    required String appVersion,
    required String machineId,
    required String machineName,
  }) => jsonEncode({
    't': 'welcome',
    'proto': kPanelProtocolVersion,
    'app': appVersion,
    'machine': {'id': machineId, 'name': machineName},
  });

  static String projects(List<PanelProject> projects) => jsonEncode({
    't': 'projects',
    'items': [for (final p in projects) p.toJson()],
  });

  static String projectUpdated(PanelProject project) =>
      jsonEncode({'t': 'project.updated', 'item': project.toJson()});

  static String turnStarted(String projectId) =>
      jsonEncode({'t': 'turn.started', 'projectId': projectId});

  /// The turn so far, as one ordered timeline.
  ///
  /// Mirrors `AgentRun.parts` (`lib/infrastructure/cli/agent_turn_part.dart`):
  /// an agent says a sentence, runs a command, reads the result, says the next
  /// sentence, and the order is the point. Sending steps as separate events
  /// would make the panel reassemble that sequence itself and get it wrong
  /// whenever a message was dropped or reordered.
  ///
  /// Sent **whole on every change**, not as a delta, because `AgentRun` is
  /// replaced wholesale upstream and a step mutates in place as it finishes —
  /// there is no append-only stream underneath to mirror.
  ///
  /// Deliberately NOT `turnPartToJson`: that is the on-disk shape, and it
  /// carries each step's request and result clipped at 800 characters. A tile
  /// draws a label and a spinner, so that payload would spend the frame budget
  /// on text no one on this screen can read.
  /// [todos] is left out entirely when the agent has no plan — which is a
  /// different fact from a plan with no steps in it, and is drawn as nothing at
  /// all rather than as an empty checklist.
  static String turnParts({
    required String projectId,
    required List<PanelTurnPart> parts,
    List<PanelTurnTodo> todos = const [],
  }) => jsonEncode({
    't': 'turn.parts',
    'projectId': projectId,
    'parts': [for (final p in parts) p.toJson()],
    if (todos.isNotEmpty) 'todos': [for (final t in todos) t.toJson()],
  });

  static String turnDone({required String projectId, required String recap}) =>
      jsonEncode({'t': 'turn.done', 'projectId': projectId, 'recap': recap});

  /// The long form of the last `recap`, for the detail screen.
  ///
  /// A separate message, and always later than the `turn.done` it belongs to:
  /// it is written by asking a model, which takes seconds, and holding the
  /// tile's "finished" on that would leave it spinning on work that is over.
  /// It may never arrive at all.
  static String summary({required String projectId, required String text}) =>
      jsonEncode({'t': 'summary', 'projectId': projectId, 'text': text});

  /// The agent has stopped mid-turn and wants permission.
  ///
  /// [options] is the whole set of answers, in the order the panel should draw
  /// them — never a fixed yes/no pair, because what the agent offered varies.
  static String question({
    required String projectId,
    required String id,
    required String summary,
    String? command,
    required List<PanelQuestionOption> options,
  }) => jsonEncode({
    't': 'question',
    'projectId': projectId,
    'id': id,
    'summary': summary,
    'command': ?command,
    'options': [for (final o in options) o.toJson()],
  });

  /// That question is settled — answered here, answered there, or expired.
  ///
  /// Sent on every route out of a question, not only the ones the panel could
  /// have caused: the desktop shows the same card, whichever surface answers
  /// first cancels the other, and a panel that is never told holds a dead card
  /// forever.
  static String questionCancel({
    required String projectId,
    required String id,
  }) => jsonEncode({'t': 'question.cancel', 'projectId': projectId, 'id': id});

  /// The heartbeat. Deliberately empty — it says the app is alive and nothing
  /// else, so a quiet link stays quiet.
  static String ping() => jsonEncode({'t': 'ping'});

  /// What the app heard, and which project it thinks it belongs to.
  ///
  /// [needsConfirm] is the honest half: the app guesses when the user spoke from
  /// a screen that names no project, and a guess that dispatches itself into a
  /// real repository is worse than one extra tap.
  static String voiceTranscript({
    required String routeId,
    required String text,
    String? projectId,
    required bool needsConfirm,
  }) => jsonEncode({
    't': 'voice.transcript',
    'routeId': routeId,
    'text': text,
    'projectId': ?projectId,
    'needsConfirm': needsConfirm,
  });

  /// Transcription failed, in words a person can act on.
  static String voiceError(String message) =>
      jsonEncode({'t': 'voice.error', 'message': message});

  /// Offer the panel the firmware this build carries.
  ///
  /// Sent when `hello` reports a version that is not the one bundled here. The
  /// panel answers `fw.accept`, and only then do the image frames start — an
  /// update must never begin in the middle of a turn the user is watching.
  static String firmwareOffer({
    required String version,
    required int size,
    required String sha256,
  }) => jsonEncode({
    't': 'fw.offer',
    'version': version,
    'size': size,
    'sha256': sha256,
  });

  static String turnError({
    required String projectId,
    required String message,
  }) => jsonEncode({
    't': 'turn.error',
    'projectId': projectId,
    'message': message,
  });
}
