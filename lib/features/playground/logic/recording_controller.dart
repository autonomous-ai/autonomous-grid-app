import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/stt_client.dart';
import '../../../infrastructure/platform/mic_recorder.dart';

/// What the mic button is doing right now.
sealed class RecordingPhase {
  const RecordingPhase();
}

/// Nothing in flight; tapping the mic starts a recording.
class RecordingIdle extends RecordingPhase {
  const RecordingIdle();
}

/// Capturing audio; tapping the mic stops it and starts transcribing.
class RecordingActive extends RecordingPhase {
  const RecordingActive();
}

/// The clip is uploaded and awaiting a transcript.
class RecordingTranscribing extends RecordingPhase {
  const RecordingTranscribing();
}

/// Recording or transcription failed. [message] is user-facing; the phase
/// reverts to [RecordingIdle] on the next tap.
class RecordingFailed extends RecordingPhase {
  const RecordingFailed(this.message);
  final String message;
}

/// Records a short voice clip and transcribes it. The mic button drives this
/// directly and feeds the result into the composer itself — the transcript
/// never touches [chatControllerProvider], since it's the input field, not
/// the transcript, that the recording produces.
class RecordingController extends Notifier<RecordingPhase> {
  Directory? _clipDir;

  @override
  RecordingPhase build() {
    ref.onDispose(_cleanUpClipDir);
    return const RecordingIdle();
  }

  /// Starts recording, or — if already recording — stops it, uploads the
  /// clip, and resolves to the transcript. Resolves to null when there is no
  /// transcript to act on: recording just started, the user cancelled, or
  /// either step failed (see [state] for why).
  Future<String?> toggle() =>
      state is RecordingActive ? _stopAndTranscribe() : _start();

  Future<String?> _start() async {
    if (ref.read(sttClientProvider) == null) {
      state = const RecordingFailed(kSttUnavailableMessage);
      return null;
    }
    final recorder = ref.read(micRecorderProvider);
    if (!await recorder.hasPermission()) {
      state = const RecordingFailed('Microphone access was denied.');
      return null;
    }
    final dir = _clipDir = Directory.systemTemp.createTempSync('grid_voice_');
    await recorder.start('${dir.path}/clip.wav');
    state = const RecordingActive();
    return null;
  }

  Future<String?> _stopAndTranscribe() async {
    final path = await ref.read(micRecorderProvider).stop();
    if (path == null) {
      state = const RecordingIdle();
      return null;
    }
    state = const RecordingTranscribing();
    try {
      final client = ref.read(sttClientProvider);
      if (client == null) {
        state = const RecordingFailed(kSttUnavailableMessage);
        return null;
      }
      final result = await client.transcribe(
        audioPath: path,
        lang: preferredSttLang(),
      );
      switch (result) {
        case SttSuccess(:final text):
          state = const RecordingIdle();
          return text;
        case SttFailure(:final message):
          state = RecordingFailed(message);
          return null;
      }
    } finally {
      _cleanUpClipDir();
    }
  }

  void _cleanUpClipDir() {
    final dir = _clipDir;
    _clipDir = null;
    if (dir == null) return;
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort: a leftover temp file costs nothing worth failing over.
    }
  }
}

final recordingControllerProvider =
    NotifierProvider<RecordingController, RecordingPhase>(
      RecordingController.new,
    );
