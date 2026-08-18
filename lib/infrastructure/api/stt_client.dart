import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/grid_cli_service.dart';
import '../providers.dart';

/// What to say when [sttClientProvider] is null — `grid` couldn't be resolved
/// on this machine.
///
/// One sentence for one cause, shared by everything that can hit it: the mic
/// button in the composer and the panel over USB ask the same question, and two
/// wordings for it would read as two different problems.
const String kSttUnavailableMessage =
    "The grid tool isn't available on this computer.";

/// What to say when `grid` is there but has never heard of `stt transcribe`.
///
/// Deliberately does not say "update it": the verb is not in a release yet, and
/// copy that sends someone to run an update which cannot fix this is worse than
/// copy that simply says what is wrong (conventions §5 — never promise a
/// fallback works). Shared by the mic button and the panel for the same reason
/// [kSttUnavailableMessage] is: one cause should not read as two problems.
const String kSttUnsupportedMessage =
    'Voice needs a newer grid tool than this computer has.';

/// 'vi' when the OS locale is Vietnamese, 'en' otherwise.
///
/// The STT endpoint has no auto-detect, so something has to pick, and the
/// system locale is the only signal available without asking. Shared for the
/// same reason as [kSttUnavailableMessage]: a panel that transcribed in a
/// different language from the composer on the same machine would be a bug
/// nobody could explain.
String preferredSttLang() =>
    PlatformDispatcher.instance.locale.languageCode.toLowerCase() == 'vi'
    ? 'vi'
    : 'en';

/// Outcome of a speech-to-text transcription.
sealed class SttResult {
  const SttResult();
}

/// Transcribed successfully. [text] is empty on silence or audio in a
/// language other than [lang] — that is a normal answer, not a failure.
class SttSuccess extends SttResult {
  const SttSuccess(this.text);
  final String text;
}

/// The transcription failed; [message] is what the mic button shows.
class SttFailure extends SttResult {
  const SttFailure(this.message);
  final String message;
}

/// Converts a short voice clip to text via `grid stt transcribe` — the CLI's authenticated
/// call to the Grid control-plane speech-to-text endpoint (Deepgram under the hood). The
/// app never talks to that endpoint directly or handles the saved session token
/// (docs/conventions.md §7: "All grid calls go through GridCliService").
abstract interface class SttClient {
  /// Transcribes the WAV already written to [audioPath]. The file stays on disk — the CLI
  /// reads it by path, the same way every other file-passing command in this app works;
  /// there is no precedent for (and no need to) re-serialize it into bytes/argv/stdin.
  /// [lang] pins the recognition model ('en' or 'vi'); the server treats anything else,
  /// including a typo, as 'vi'.
  Future<SttResult> transcribe({
    required String audioPath,
    required String lang,
  });
}

/// Real [SttClient] over `grid stt transcribe`, mirroring `CodeCli`'s "run the command,
/// read stdout" shape (code_cli.dart) for a plain-text transcript.
class GridCliSttClient implements SttClient {
  const GridCliSttClient(this._service);

  final GridCliService _service;

  /// How long the CLI is given to upload the clip and get an answer, passed to it
  /// explicitly as `--timeout`.
  ///
  /// **The flag is passed rather than left at its default**, which is 30s
  /// (`cli/stt.py`) and was written for a clip of a few seconds. A panel capture
  /// may now be ten minutes — 19.2 MB to upload before the transcriber has heard
  /// a word of it — and a timeout that fires there loses a recording somebody has
  /// already finished making, which is the worst moment to lose one.
  static const _cliTimeout = Duration(seconds: 120);

  /// A little past [_cliTimeout] so the CLI's own timeout message wins the race
  /// instead of a generic "command timed out."
  static const _timeout = Duration(seconds: 125);

  @override
  Future<SttResult> transcribe({
    required String audioPath,
    required String lang,
  }) async {
    final result = await _service.run([
      'stt',
      'transcribe',
      audioPath,
      '--lang',
      lang,
      '--timeout',
      '${_cliTimeout.inSeconds}',
    ], timeout: _timeout);
    if (!result.ok) return SttFailure(_messageFor(result));
    return SttSuccess(result.stdout.trim());
  }

  /// Most of the CLI's own refusals (not signed in, file not found, a network error)
  /// are already full sentences on stderr and pass through as-is. The one case that isn't
  /// is a non-2xx from the Grid control plane, which `cmd_stt_transcribe` reports as
  /// `HTTP <code>: <raw body>` — recognised here and turned into the same wording the old
  /// direct-HTTP client used to show.
  static String _messageFor(CliResult result) {
    final raw = result.errorMessage.trim();
    if (raw.isEmpty) {
      return "Couldn't transcribe: the grid tool gave no reason.";
    }
    final match = RegExp(r'^HTTP (\d+):').firstMatch(raw);
    if (match != null) {
      return _messageForStatus(int.parse(match.group(1)!));
    }
    if (raw.toLowerCase().contains('timed out')) {
      return "The server didn't respond in time.";
    }
    if (_isUnknownCommand(raw)) return kSttUnsupportedMessage;
    if (raw.length <= 400) {
      return raw;
    }
    return '${raw.substring(0, 399)}…';
  }

  /// Whether [raw] is argparse refusing the subcommand rather than the command
  /// failing.
  ///
  /// The pass-through above assumes the CLI's refusals are sentences, and most
  /// are. This one is not: an unknown subcommand prints a usage block and the
  /// full list of verbs the build does know — around 380 characters, which slips
  /// under the cap and lands on screen whole. On a 466px round panel that is a
  /// wall of grey text where a sentence belongs (seen on hardware 2026-08-17).
  ///
  /// Matched on the shape rather than on the word `stt`, because the same thing
  /// will happen to the next verb this app learns before the CLI ships it.
  static bool _isUnknownCommand(String raw) {
    final text = raw.toLowerCase();
    return text.contains('invalid choice') ||
        (text.contains('usage: grid') && text.contains('error: argument'));
  }

  static String _messageForStatus(int status) => switch (status) {
    401 => 'Your Grid session has expired. Run `grid login` to sign in again.',
    400 => "Couldn't send the recording. Try again.",
    413 => 'That recording is too long. Try a shorter one.',
    503 => 'Voice input is not set up on the server yet.',
    >= 500 => 'The transcription service had a problem. Try again.',
    _ => "Couldn't transcribe (error $status).",
  };
}

/// The STT seam. Null when `grid` can't be found — the same gate every other CLI-backed
/// feature in this app shares (see [gridCliServiceProvider]); the mic button then
/// disables itself with an explanation instead of spawning a command that can't run.
final sttClientProvider = Provider<SttClient?>((ref) {
  final service = ref.watch(gridCliServiceProvider);
  return service == null ? null : GridCliSttClient(service);
});
