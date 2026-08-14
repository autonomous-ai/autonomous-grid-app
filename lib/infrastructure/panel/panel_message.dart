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
  });

  final String id;
  final String name;
  final String? agent;
  final String? model;
  final bool busy;
  final String recap;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (agent != null) 'agent': agent,
    if (model != null) 'model': model,
    'busy': busy,
    if (recap.isNotEmpty) 'recap': recap,
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
  const PanelTurnPart.text(String text) : label = text, status = null;

  /// A step the agent ran, with where it has got to.
  const PanelTurnPart.step({required this.label, required String this.status});

  /// The prose, or the step's one-line label.
  final String label;

  /// The step's status, or null when this is prose.
  final String? status;

  bool get isStep => status != null;

  Map<String, Object?> toJson() => status == null
      ? {'k': 't', 'text': label}
      : {'k': 's', 'label': label, 'status': status};
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
  static String turnParts({
    required String projectId,
    required List<PanelTurnPart> parts,
  }) => jsonEncode({
    't': 'turn.parts',
    'projectId': projectId,
    'parts': [for (final p in parts) p.toJson()],
  });

  static String turnDone({required String projectId, required String recap}) =>
      jsonEncode({'t': 'turn.done', 'projectId': projectId, 'recap': recap});

  static String turnError({
    required String projectId,
    required String message,
  }) => jsonEncode({
    't': 'turn.error',
    'projectId': projectId,
    'message': message,
  });
}
