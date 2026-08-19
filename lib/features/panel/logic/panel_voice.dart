import 'dart:typed_data';

import '../../../infrastructure/panel/panel_audio.dart';
import '../../../infrastructure/panel/panel_message.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../projects/logic/project.dart';
import 'panel_turn_mirror.dart';

/// The most audio one capture may hold — ten minutes at 16 kHz, 16-bit mono,
/// which is 19.2 MB.
///
/// A bound on damage, not a target. `voice.end` is a single message on a cable,
/// and the panel reboots, the cable is nudged, a frame is dropped — any of which
/// leaves a capture open with nothing left to close it. Without a ceiling that
/// buffer grows for as long as the panel stays plugged in, which is a leak that
/// only shows up on the day someone leaves the desk mid-sentence.
///
/// **Ten rather than one** (2026-08-18) because the minute was never a decision
/// about speech: the panel's record buffer was linear rather than a ring, so it
/// filled at 65 s and 60 was the number that fit underneath. Over a cable there
/// is no reason to accept less than the reference firmware does over WiFi.
///
/// ⚠️ **This number is bounded from above by the server**, which refuses a clip
/// over 25 MiB (`MAX_AUDIO_BYTES`, autonomous-grid-be). The invariant is
/// `seconds * rate * 2 < 25 MiB` — at 16 kHz the ceiling is ~13.6 minutes, and
/// raising [kPanelVoiceSampleRate] without lowering this returns HTTP 413 to
/// somebody who has just spoken for ten minutes. Asserted in
/// `test/panel/panel_voice_test.dart`.
const int kPanelVoiceMaxBytes = 600 * kPanelVoiceSampleRate * 2;

/// How long a capture may stay open before the app finishes it itself.
///
/// The byte cap bounds the memory; this bounds the *wait*. A panel whose
/// `voice.end` never arrived is a panel sitting on a screen that says it is
/// listening, and it has no other way to find out otherwise: it runs no model
/// and cannot see this app. Deliberately longer than the byte cap allows, so a
/// capture that filled up is closed by the bytes and this only ever fires for a
/// panel that went quiet.
const Duration kPanelVoiceOpenLimit = Duration(seconds: 660);

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
    this.chatId,
    this.command = PanelVoiceCommand.none,
    this.lang,
    this.limitBytes = kPanelVoiceMaxBytes,
  });

  /// The chat the panel was showing when the user started speaking, or null
  /// when they spoke from a screen that names none — which is what makes
  /// routing a decision (see [panelVoiceRouteFor]) rather than a lookup.
  final String? chatId;

  /// Which pill started this capture. Carried on the capture rather than read
  /// again at the end, because by then the panel may already be showing a
  /// different tile with a different pill lit.
  final PanelVoiceCommand command;

  /// The language the device asked for, or null when it named none. Carried on
  /// the capture rather than read again at the end, for the same reason
  /// [command] is: by then the Settings page may have been changed again, and
  /// this clip was spoken under the old setting.
  final String? lang;

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

/// The panel named the chat, so this goes there without asking.
class PanelVoiceRouted extends PanelVoiceRoute {
  const PanelVoiceRouted(this.chatId);

  final String chatId;
}

/// Nobody named a chat. This is the app's best guess, and it is sent with
/// `needsConfirm` so the panel asks before anything runs.
class PanelVoiceGuessed extends PanelVoiceRoute {
  const PanelVoiceGuessed(this.chatId);

  final String chatId;
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
/// - A chat the panel named wins outright.
/// - A chat the panel named that this computer no longer has is refused in
///   words rather than re-guessed — the user picked a tile, and quietly sending
///   their words somewhere else is exactly the failure the confirm step exists
///   to prevent.
/// - Otherwise the guess is the chat talked in most recently, which is the only
///   signal the app has about what the person at the panel is working on. It is
///   only a fallback: [PanelVoiceGuessed] is what puts the question to a model
///   (and then to the user), rather than an answer.
PanelVoiceRoute panelVoiceRouteFor({
  required String? spokenIn,
  required List<Project> projects,
  required ChatSessionsState chats,
}) {
  final tiles = panelTileChatsOf(projects, chats);
  if (tiles.isEmpty) {
    return const PanelVoiceUnroutable(
      'There are no chats on this computer yet. Start one in Grid first.',
    );
  }
  final named = spokenIn?.trim() ?? '';
  if (named.isNotEmpty) {
    if (tiles.contains(named)) return PanelVoiceRouted(named);
    return const PanelVoiceUnroutable('This computer no longer has that chat.');
  }
  return PanelVoiceGuessed(_mostRecentlyUsed(tiles, chats) ?? tiles.first);
}

/// The tile chat touched last, or null when none of them has ever been talked
/// in.
String? _mostRecentlyUsed(Set<String> tiles, ChatSessionsState chats) {
  String? best;
  DateTime? bestAt;
  for (final conversation in chats.live) {
    if (!tiles.contains(conversation.id)) continue;
    if (bestAt != null && !conversation.updatedAt.isAfter(bestAt)) continue;
    best = conversation.id;
    bestAt = conversation.updatedAt;
  }
  return best;
}
