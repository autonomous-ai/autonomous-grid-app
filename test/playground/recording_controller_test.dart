import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/recording_controller.dart';
import 'package:grid_app/infrastructure/api/stt_client.dart';
import 'package:grid_app/infrastructure/platform/mic_recorder.dart';

/// Writes to the path it's told to start at (mimicking a real recorder
/// writing the clip as it goes) and hands the same path back on [stop] —
/// unless [failStop], simulating a recorder with nothing to give.
class _FakeMicRecorder implements MicRecorder {
  _FakeMicRecorder({this.permission = true, this.failStop = false});

  final bool permission;
  final bool failStop;
  String? startPath;
  bool stopped = false;
  bool disposed = false;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start(String path) async {
    startPath = path;
    await File(path).writeAsBytes(const [1, 2, 3]);
  }

  @override
  Future<String?> stop() async {
    stopped = true;
    return failStop ? null : startPath;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeSttClient implements SttClient {
  _FakeSttClient(this.result);
  final SttResult result;
  String? audioPath;
  String? lang;

  @override
  Future<SttResult> transcribe({
    required String audioPath,
    required String lang,
  }) async {
    this.audioPath = audioPath;
    this.lang = lang;
    return result;
  }
}

ProviderContainer _container({MicRecorder? recorder, SttClient? stt}) {
  final container = ProviderContainer(
    overrides: [
      if (recorder != null) micRecorderProvider.overrideWithValue(recorder),
      sttClientProvider.overrideWithValue(stt),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'starting with no grid tool available fails without touching the mic',
    () async {
      final recorder = _FakeMicRecorder();
      final container = _container(recorder: recorder, stt: null);

      final transcript = await container
          .read(recordingControllerProvider.notifier)
          .toggle();

      expect(transcript, isNull);
      expect(recorder.startPath, isNull);
      final phase = container.read(recordingControllerProvider);
      expect(phase, isA<RecordingFailed>());
      expect(
        (phase as RecordingFailed).message,
        "The grid tool isn't available on this computer.",
      );
    },
  );

  test('denied microphone permission fails before recording starts', () async {
    final recorder = _FakeMicRecorder(permission: false);
    final container = _container(
      recorder: recorder,
      stt: _FakeSttClient(const SttSuccess('unused')),
    );

    final transcript = await container
        .read(recordingControllerProvider.notifier)
        .toggle();

    expect(transcript, isNull);
    expect(recorder.startPath, isNull);
    expect(
      container.read(recordingControllerProvider),
      isA<RecordingFailed>(),
    );
  });

  test('tapping while idle starts a recording', () async {
    final recorder = _FakeMicRecorder();
    final container = _container(
      recorder: recorder,
      stt: _FakeSttClient(const SttSuccess('unused')),
    );

    final transcript = await container
        .read(recordingControllerProvider.notifier)
        .toggle();

    expect(transcript, isNull);
    expect(recorder.startPath, isNotNull);
    expect(
      container.read(recordingControllerProvider),
      isA<RecordingActive>(),
    );
  });

  test(
    'tapping while recording stops it, transcribes, and returns the text',
    () async {
      final recorder = _FakeMicRecorder();
      final stt = _FakeSttClient(const SttSuccess('turn on the lights'));
      final container = _container(recorder: recorder, stt: stt);
      final notifier = container.read(recordingControllerProvider.notifier);
      await notifier.toggle(); // start

      final transcript = await notifier.toggle(); // stop + transcribe

      expect(transcript, 'turn on the lights');
      expect(recorder.stopped, isTrue);
      // The on-disk clip path flows through unchanged — no bytes re-read.
      expect(stt.audioPath, recorder.startPath);
      expect(stt.lang, isNotNull);
      expect(container.read(recordingControllerProvider), isA<RecordingIdle>());
    },
  );

  test('a failed transcription surfaces the reason and returns null', () async {
    final recorder = _FakeMicRecorder();
    final stt = _FakeSttClient(const SttFailure('The server had a problem.'));
    final container = _container(recorder: recorder, stt: stt);
    final notifier = container.read(recordingControllerProvider.notifier);
    await notifier.toggle(); // start

    final transcript = await notifier.toggle(); // stop + transcribe

    expect(transcript, isNull);
    final phase = container.read(recordingControllerProvider);
    expect(phase, isA<RecordingFailed>());
    expect((phase as RecordingFailed).message, 'The server had a problem.');
  });

  test('stopping a recorder with nothing captured returns to idle', () async {
    final recorder = _FakeMicRecorder(failStop: true);
    final stt = _FakeSttClient(const SttSuccess('unused'));
    final container = _container(recorder: recorder, stt: stt);
    final notifier = container.read(recordingControllerProvider.notifier);
    await notifier.toggle(); // start

    final transcript = await notifier.toggle(); // stop finds nothing

    expect(transcript, isNull);
    expect(container.read(recordingControllerProvider), isA<RecordingIdle>());
  });
}
