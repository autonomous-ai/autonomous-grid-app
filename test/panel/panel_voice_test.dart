import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/panel/logic/panel_voice.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/infrastructure/panel/panel_audio.dart';

Conversation _chat({
  required String id,
  required String projectId,
  required DateTime at,
}) => Conversation(
  id: id,
  title: 'A chat',
  model: 'qwen',
  createdAt: at,
  updatedAt: at,
  projectId: projectId,
);

const _projects = [
  Project(id: 'p-1', name: 'grid-app', path: '/tmp/grid-app'),
  Project(id: 'p-2', name: 'notes', path: '/tmp/notes'),
];

/// The four-character tag at [offset], as WAV writes them.
String _tag(Uint8List wav, int offset) =>
    String.fromCharCodes(wav.sublist(offset, offset + 4));

int _u32(Uint8List wav, int offset) =>
    ByteData.sublistView(wav).getUint32(offset, Endian.little);

int _u16(Uint8List wav, int offset) =>
    ByteData.sublistView(wav).getUint16(offset, Endian.little);

void main() {
  group('the WAV the transcriber is handed', () {
    test('says 16 kHz mono 16-bit — the format the panel captured in, which '
        'nothing between here and the transcriber can restate', () {
      // A header that disagrees with the samples does not sound wrong. It comes
      // back as an empty transcript, three layers from the mistake.
      final wav = wavFromPcm16(Uint8List(320));

      expect(_tag(wav, 0), 'RIFF');
      expect(_tag(wav, 8), 'WAVE');
      expect(_tag(wav, 12), 'fmt ');
      expect(_u32(wav, 16), 16); // a PCM fmt chunk, no codec
      expect(_u16(wav, 20), 1); // uncompressed
      expect(_u16(wav, 22), kPanelVoiceChannels);
      expect(_u32(wav, 24), kPanelVoiceSampleRate);
      expect(_u16(wav, 34), kPanelVoiceBitsPerSample);
      // Byte rate and block align are derived, and a reader that trusts them
      // over the fields above will play the clip at the wrong speed.
      expect(_u32(wav, 28), kPanelVoiceSampleRate * 2);
      expect(_u16(wav, 32), 2);
    });

    test('carries the samples through untouched, because both sides already '
        'speak little-endian 16-bit', () {
      final pcm = Uint8List.fromList([0x01, 0x80, 0xFF, 0x7F]);
      final wav = wavFromPcm16(pcm);

      expect(_tag(wav, 36), 'data');
      expect(_u32(wav, 40), 4);
      expect(wav.sublist(kWavHeaderBytes), pcm);
      // The RIFF size counts everything after its own field.
      expect(_u32(wav, 4), wav.length - 8);
    });

    test('drops a trailing half sample rather than shifting every one after '
        'it', () {
      // A chunk cut mid-sample would move every following byte by one, which
      // does not sound like a clipped recording — it sounds like static.
      final wav = wavFromPcm16(Uint8List.fromList([1, 2, 3]));
      expect(_u32(wav, 40), 2);
      expect(wav.length, kWavHeaderBytes + 2);
    });
  });

  group('collecting what the panel is saying', () {
    test('keeps the audio in the order it arrived', () {
      final capture = PanelVoiceCapture(projectId: 'p-1')
        ..add([1, 2])
        ..add([3, 4]);

      expect(capture.length, 4);
      expect(capture.truncated, isFalse);
      expect(capture.toWav().sublist(kWavHeaderBytes), [1, 2, 3, 4]);
    });

    test('stops at its ceiling, so a voice.end that never arrives cannot grow '
        'a buffer for as long as the cable is plugged in', () {
      final capture = PanelVoiceCapture(limitBytes: 6)
        ..add([1, 2, 3, 4])
        ..add([5, 6, 7, 8])
        ..add([9, 10]);

      expect(capture.length, 6);
      expect(capture.isFull, isTrue);
      expect(capture.truncated, isTrue);
      // What it kept is the start of the sentence, not a window of the end.
      expect(capture.toWav().sublist(kWavHeaderBytes), [1, 2, 3, 4, 5, 6]);
    });

    test('a minute of speech fits under the ceiling, so the bound is a guard '
        'rather than a limit anyone meets', () {
      expect(kPanelVoiceMaxBytes, 60 * kPanelVoiceSampleRate * 2);
    });
  });

  group('deciding where a transcript goes', () {
    test('a project the panel named wins outright — the user was looking at '
        'that tile when they spoke', () {
      final route = panelVoiceRouteFor(
        spokenIn: 'p-2',
        projects: _projects,
        chats: const ChatSessionsState(),
      );
      expect(route, isA<PanelVoiceRouted>());
      expect((route as PanelVoiceRouted).projectId, 'p-2');
    });

    test('with no project named the app guesses, and says it is guessing — a '
        'guess that dispatches itself into a real repository is worse than '
        'one extra tap', () {
      final route = panelVoiceRouteFor(
        spokenIn: null,
        projects: _projects,
        chats: ChatSessionsState(
          conversations: [
            _chat(id: 'c-1', projectId: 'p-1', at: DateTime(2026, 8, 1)),
            _chat(id: 'c-2', projectId: 'p-2', at: DateTime(2026, 8, 13)),
          ],
        ),
      );
      // The project talked in most recently: the only signal the app has about
      // what the person standing at the panel is working on.
      expect(route, isA<PanelVoiceGuessed>());
      expect((route as PanelVoiceGuessed).projectId, 'p-2');
    });

    test('an empty project id is the same as none — a missing key falls back '
        'to a zero value on this wire, and "" is not a project', () {
      final route = panelVoiceRouteFor(
        spokenIn: '',
        projects: _projects,
        chats: const ChatSessionsState(),
      );
      expect(route, isA<PanelVoiceGuessed>());
    });

    test('with nothing said anywhere yet the guess is the first project the '
        'app lists, which is the one at the front of the panel too', () {
      final route = panelVoiceRouteFor(
        spokenIn: null,
        projects: _projects,
        chats: const ChatSessionsState(),
      );
      expect((route as PanelVoiceGuessed).projectId, 'p-1');
    });

    test('a project this computer no longer has is refused in words rather '
        'than quietly re-guessed', () {
      // The user picked a tile. Sending their sentence somewhere else is the
      // exact failure the confirm step exists to prevent.
      final route = panelVoiceRouteFor(
        spokenIn: 'p-gone',
        projects: _projects,
        chats: const ChatSessionsState(),
      );
      expect(route, isA<PanelVoiceUnroutable>());
      expect((route as PanelVoiceUnroutable).message, contains('project'));
    });

    test('a computer with no projects at all names the step the user is '
        'missing, instead of failing at them', () {
      final route = panelVoiceRouteFor(
        spokenIn: null,
        projects: const [],
        chats: const ChatSessionsState(),
      );
      expect(route, isA<PanelVoiceUnroutable>());
      expect((route as PanelVoiceUnroutable).message, contains('Grid'));
    });
  });
}
