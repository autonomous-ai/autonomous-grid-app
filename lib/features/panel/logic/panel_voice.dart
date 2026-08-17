import 'dart:typed_data';

import '../../../infrastructure/panel/panel_audio.dart';
import '../../../infrastructure/panel/panel_message.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../projects/logic/project.dart';

/// The most audio one capture may hold — sixty seconds at 16 kHz, 16-bit mono.
///
/// A bound on damage, not a target: nobody dictates a minute into a 480px tile.
/// `voice.end` is a single message on a cable, and the panel reboots, the cable
/// is nudged, a frame is dropped — any of which leaves a capture open with
/// nothing left to close it. Without a ceiling that buffer grows for as long as
/// the panel stays plugged in, which is a leak that only shows up on the day
/// someone leaves the desk mid-sentence.
const int kPanelVoiceMaxBytes = 60 * kPanelVoiceSampleRate * 2;

/// How long a capture may stay open before the app finishes it itself.
///
/// The byte cap bounds the memory; this bounds the *wait*. A panel whose
/// `voice.end` never arrived is a panel sitting on a screen that says it is
/// listening, and it has no other way to find out otherwise: it runs no model
/// and cannot see this app. Deliberately longer than the byte cap allows, so a
/// capture that filled up is closed by the bytes and this only ever fires for a
/// panel that went quiet.
const Duration kPanelVoiceOpenLimit = Duration(seconds: 75);

/// How many guessed transcripts wait for a `voice.confirm` at once.
///
/// The panel asks about one at a time, so this is only ever reached by a user
/// who spoke, was asked where it should go, and walked away — several times
/// over. Their unanswered questions are dropped oldest first rather than kept
/// for a session that may last days.
const int kPanelVoicePendingLimit = 4;

/// Audio arriving between `voice.begin` and `voice.end`.
///
/// Bounded by construction: past [limitBytes] the samples are dropped rather
/// than buffered, and [truncated] says so. Losing the tail of a very long
/// sentence is a bad outcome; growing without limit on a message that may never
/// come is a worse one.
class PanelVoiceCapture {
  PanelVoiceCapture({
    this.projectId,
    this.command = PanelVoiceCommand.none,
    this.limitBytes = kPanelVoiceMaxBytes,
  });

  /// The project the panel was showing when the user started speaking, or null
  /// when they spoke from a screen that names none — which is what makes
  /// routing a decision (see [panelVoiceRouteFor]) rather than a lookup.
  final String? projectId;

  /// Which pill started this capture. Carried on the capture rather than read
  /// again at the end, because by then the panel may already be showing a
  /// different tile with a different pill lit.
  final PanelVoiceCommand command;

  final int limitBytes;

  final _pcm = BytesBuilder(copy: false);
  bool _truncated = false;

  /// Bytes held so far.
  int get length => _pcm.length;

  /// Whether anything was dropped for want of room.
  bool get truncated => _truncated;

  /// Whether the buffer is full, and so the capture should be finished now
  /// rather than when the panel gets round to saying so.
  bool get isFull => _pcm.length >= limitBytes;

  /// Append one PCM chunk, keeping only what fits.
  void add(List<int> chunk) {
    final room = limitBytes - _pcm.length;
    if (room <= 0) {
      _truncated = true;
      return;
    }
    if (chunk.length <= room) {
      _pcm.add(chunk);
      return;
    }
    _truncated = true;
    _pcm.add(chunk.sublist(0, room));
  }

  /// The audio as a WAV file, ready for `grid stt transcribe`.
  Uint8List toWav() => wavFromPcm16(_pcm.toBytes());

  /// How long the capture is, in seconds **at the rate the protocol fixes** —
  /// which is a reading, not a measurement. A device recording at another rate
  /// makes this number wrong by exactly that ratio, and it will still look
  /// plausible: 4.4 seconds of speech captured at 8 kHz reads as 2.2 here.
  double get seconds => _pcm.length / (kPanelVoiceSampleRate * 2);

  /// One line describing the audio, for the log when nothing was transcribed.
  ///
  /// Assembled here because this is where the sample rate is known; the caller
  /// would have to import the audio layer to say the same thing.
  String describe() =>
      '$length bytes (${seconds.toStringAsFixed(1)}s at '
      '${kPanelVoiceSampleRate}Hz), peaking at $peakAmplitude/32767';

  /// The loudest sample in the capture, 0…32767.
  ///
  /// The one number that tells a silent microphone from a transcriber that heard
  /// words it could not place. Both come back as an empty transcript, and
  /// without this they read as the same failure — which cost a debugging session
  /// on 2026-08-17, when "I couldn't make out any words" was reported for audio
  /// nobody had yet established was audio.
  ///
  /// Read as little-endian signed 16-bit, exactly as [wavFromPcm16] stores it,
  /// so a peak of zero here means the bytes really are silence rather than
  /// meaning this reading disagrees with the container.
  int get peakAmplitude {
    final bytes = _pcm.toBytes();
    final samples = Int16List.sublistView(
      bytes,
      0,
      bytes.length - bytes.length % 2,
    );
    var peak = 0;
    for (final sample in samples) {
      // -32768 has no positive counterpart; clamping it keeps the range honest
      // rather than overflowing into a negative "peak".
      final magnitude = sample == -32768 ? 32767 : sample.abs();
      if (magnitude > peak) peak = magnitude;
    }
    return peak;
  }
}

/// Where a transcript is going.
///
/// Sealed so the caller has to face the middle case: the app guessed, and a
/// guess that dispatches itself into a real repository is worse than one extra
/// tap (`docs/protocol.md` §2, Voice).
sealed class PanelVoiceRoute {
  const PanelVoiceRoute();
}

/// The panel named the project, so this goes there without asking.
class PanelVoiceRouted extends PanelVoiceRoute {
  const PanelVoiceRouted(this.projectId);

  final String projectId;
}

/// Nobody named a project. This is the app's best guess, and it is sent with
/// `needsConfirm` so the panel asks before anything runs.
class PanelVoiceGuessed extends PanelVoiceRoute {
  const PanelVoiceGuessed(this.projectId);

  final String projectId;
}

/// There is nowhere to send it. [message] is what the panel shows, and it names
/// the thing the user can go and do.
class PanelVoiceUnroutable extends PanelVoiceRoute {
  const PanelVoiceUnroutable(this.message);

  final String message;
}

/// Decide where the transcript of a capture that began in [spokenIn] goes.
///
/// Pure, and the whole of the hard half of voice: transcription either works or
/// says why, while routing can be confidently wrong. The rules, in order:
///
/// - A project the panel named wins outright.
/// - A project the panel named that this computer no longer has is refused in
///   words rather than re-guessed — the user picked a tile, and quietly sending
///   their words somewhere else is exactly the failure the confirm step exists
///   to prevent.
/// - Otherwise the guess is the project talked in most recently, which is the
///   only signal the app has about what the person at the panel is working on,
///   falling back to the first project it lists when nothing has been said
///   anywhere yet.
PanelVoiceRoute panelVoiceRouteFor({
  required String? spokenIn,
  required List<Project> projects,
  required ChatSessionsState chats,
}) {
  if (projects.isEmpty) {
    return const PanelVoiceUnroutable(
      'There are no projects on this computer yet. Add one in Grid first.',
    );
  }
  final named = spokenIn?.trim() ?? '';
  if (named.isNotEmpty) {
    if (projects.any((project) => project.id == named)) {
      return PanelVoiceRouted(named);
    }
    return const PanelVoiceUnroutable(
      'This computer no longer has that project.',
    );
  }
  return PanelVoiceGuessed(
    _mostRecentlyUsed(projects, chats) ?? projects.first.id,
  );
}

/// The project whose chat was touched last, or null when none of the listed
/// projects has ever been talked in.
///
/// Archived chats are excluded with the rest by [ChatSessionsState.live]: a
/// project the user filed away is not what they are working on now.
String? _mostRecentlyUsed(List<Project> projects, ChatSessionsState chats) {
  final known = {for (final project in projects) project.id};
  String? best;
  DateTime? bestAt;
  for (final conversation in chats.live) {
    final projectId = conversation.projectId;
    if (projectId == null || !known.contains(projectId)) continue;
    if (bestAt != null && !conversation.updatedAt.isAfter(bestAt)) continue;
    best = projectId;
    bestAt = conversation.updatedAt;
  }
  return best;
}
