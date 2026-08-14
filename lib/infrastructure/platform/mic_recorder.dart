import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

/// Records microphone audio to a file. A thin seam over `package:record`'s
/// [AudioRecorder] so [RecordingController] can be driven by a fake instead
/// of a real microphone and platform channel in tests.
abstract interface class MicRecorder {
  /// Prompts for microphone access if needed; true once it's granted.
  Future<bool> hasPermission();

  /// Starts recording 16-bit WAV to [path] — the container Deepgram is
  /// verified to accept without transcoding.
  Future<void> start(String path);

  /// Stops recording and returns the file path, or null if nothing was
  /// recording.
  Future<String?> stop();

  Future<void> dispose();
}

class PackageMicRecorder implements MicRecorder {
  final _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start(String path) => _recorder.start(
    const RecordConfig(encoder: AudioEncoder.wav),
    path: path,
  );

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// The mic seam. One recorder per app session — starting/stopping the same
/// instance is how `package:record` expects to be driven.
final micRecorderProvider = Provider<MicRecorder>((ref) {
  final recorder = PackageMicRecorder();
  ref.onDispose(() => unawaited(recorder.dispose()));
  return recorder;
});
