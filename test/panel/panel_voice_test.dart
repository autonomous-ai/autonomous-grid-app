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
      final capture = PanelVoiceCapture(chatId: 'p-1')
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

    test(
      'the ceiling is ten minutes of speech — the same allowance the panel '
      'draws, so neither half cuts a recording the other would have taken',
      () {
        expect(kPanelVoiceMaxBytes, 600 * kPanelVoiceSampleRate * 2);
      },
    );

    test('a full capture still fits the 25 MiB the control plane accepts, or '
        'the server refuses a recording somebody has just finished making', () {
      // MAX_AUDIO_BYTES in autonomous-grid-be/grid_networks/transcription.py.
      // Duplicated here because nothing links the two repositories, and the
      // failure it guards is the worst-timed one there is: HTTP 413 after ten
      // minutes of speech. At 16 kHz the server's ceiling is ~13.6 minutes, so
      // this is the assertion that breaks if the sample rate is ever raised
      // without lowering the cap.
      expect(kPanelVoiceMaxBytes, lessThan(25 * 1024 * 1024));
    });
  });

  group('deciding where a transcript goes', () {
    // Two chats in ONE project and one in another, which is the shape that
    // broke the old model: a tile stood for a folder, so these three were two
    // tiles and the panel could not name the chat the user was standing at.
    final live = ChatSessionsState(
      conversations: [
        _chat(id: 'c-1', projectId: 'p-1', at: DateTime(2026, 8, 1)),
        _chat(id: 'c-2', projectId: 'p-1', at: DateTime(2026, 8, 13)),
        _chat(id: 'c-3', projectId: 'p-2', at: DateTime(2026, 8, 12)),
      ],
    );

    test('the chat the panel named wins outright — the user was looking at '
        'that tile when they spoke', () {
      final route = panelVoiceRouteFor(
        spokenIn: 'c-2',
        projects: _projects,
        chats: live,
      );
      expect(route, isA<PanelVoiceRouted>());
      expect((route as PanelVoiceRouted).chatId, 'c-2');
    });

    test('a chat named in the SAME project as another is still named exactly '
        '— the two are separate tiles and separate conversations', () {
      final route = panelVoiceRouteFor(
        spokenIn: 'c-1',
        projects: _projects,
        chats: live,
      );
      expect((route as PanelVoiceRouted).chatId, 'c-1');
    });

    test('with no chat named the app guesses, and says it is guessing — a '
        'guess that dispatches itself into a real repository is worse than '
        'one extra tap', () {
      final route = panelVoiceRouteFor(
        spokenIn: null,
        projects: _projects,
        chats: live,
      );
      // The chat talked in most recently: the only signal the app has about
      // what the person standing at the panel is working on.
      expect(route, isA<PanelVoiceGuessed>());
      expect((route as PanelVoiceGuessed).chatId, 'c-2');
    });

    test('an empty chat id is the same as none — a missing key falls back to '
        'a zero value on this wire, and "" is not a chat', () {
      final route = panelVoiceRouteFor(
        spokenIn: '',
        projects: _projects,
        chats: live,
      );
      expect(route, isA<PanelVoiceGuessed>());
    });

    test('with nothing said anywhere yet the guess is the first tile the app '
        'lists, which is the one at the front of the panel too', () {
      final route = panelVoiceRouteFor(
        spokenIn: null,
        projects: _projects,
        chats: ChatSessionsState(
          conversations: [_chat(id: 'c-9', projectId: 'p-1', at: _epoch)],
        ),
      );
      expect((route as PanelVoiceGuessed).chatId, 'c-9');
    });

    test('a chat this computer no longer has is refused in words rather than '
        'quietly re-guessed', () {
      // The user picked a tile. Sending their sentence somewhere else is the
      // exact failure the confirm step exists to prevent.
      final route = panelVoiceRouteFor(
        spokenIn: 'c-gone',
        projects: _projects,
        chats: live,
      );
      expect(route, isA<PanelVoiceUnroutable>());
      expect((route as PanelVoiceUnroutable).message, contains('chat'));
    });

    test('a chat whose project the app no longer lists is refused too — the '
        'panel was never sent a tile for it', () {
      final route = panelVoiceRouteFor(
        spokenIn: 'c-orphan',
        projects: _projects,
        chats: ChatSessionsState(
          conversations: [
            _chat(
              id: 'c-orphan',
              projectId: 'p-gone',
              at: DateTime(2026, 8, 1),
            ),
          ],
        ),
      );
      expect(route, isA<PanelVoiceUnroutable>());
    });

    test('a computer with no chats at all names the step the user is missing, '
        'instead of failing at them', () {
      final route = panelVoiceRouteFor(
        spokenIn: null,
        projects: _projects,
        chats: const ChatSessionsState(),
      );
      expect(route, isA<PanelVoiceUnroutable>());
      expect((route as PanelVoiceUnroutable).message, contains('Grid'));
    });
  });
}

final _epoch = DateTime(2026, 1, 1);
