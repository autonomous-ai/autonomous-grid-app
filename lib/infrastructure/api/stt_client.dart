import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/grid_cli_service.dart';
import '../providers.dart';

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

  /// A little past the CLI's own httpx timeout (cli/stt.py's `--timeout`, default 30s) so
  /// the CLI's own timeout message wins the race instead of a generic "command timed out."
  static const _timeout = Duration(seconds: 35);

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
    if (raw.length <= 400) {
      return raw;
    }
    return '${raw.substring(0, 399)}…';
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
