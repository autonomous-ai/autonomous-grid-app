import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_pictures.dart';
import 'package:grid_app/infrastructure/api/telegram_bot_api.dart';
import 'package:grid_app/infrastructure/api/telegram_wire.dart';
import 'package:grid_app/infrastructure/logging/app_log.dart';

/// A message from Telegram, with [pictureId] when it carries a picture and
/// [pictureName] when that picture came as a file, under a name of its own.
TelegramText _message({
  String text = '',
  String? pictureId,
  String? pictureName,
}) => TelegramText(
  updateId: 1,
  chatId: 42,
  privateChat: true,
  fromId: 42,
  fromName: 'Huy',
  text: text,
  sentAt: DateTime(2026, 9, 18),
  pictureId: pictureId,
  pictureName: pictureName,
);

/// Telegram's file host, answered from memory: it hands over [file], or throws
/// [failure], and remembers what it was asked for.
///
/// Every other call is a mistake here, so it fails the test rather than
/// answering.
class _Files implements TelegramBotApi {
  _Files({this.file, this.failure});

  final TelegramFile? file;
  final TelegramFailure? failure;
  final List<String> asked = [];

  @override
  Future<TelegramFile> downloadFile(String fileId) async {
    asked.add(fileId);
    final failure = this.failure;
    if (failure != null) throw failure;
    return file!;
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      fail('The picture fetch called ${invocation.memberName}');
}

TelegramFile _file(String name) =>
    (name: name, bytes: Uint8List.fromList([1, 2, 3]));

void main() {
  group('the words a picture brings', () {
    test('a bare picture asks the assistant to look, since a turn with no '
        'words is dropped before it is sent', () {
      expect(
        telegramTurnText(_message(pictureId: 'p')),
        kTelegramBarePicturePrompt,
      );
    });

    test("a caption is the question, and plain text isn't touched", () {
      expect(
        telegramTurnText(_message(text: 'why red?', pictureId: 'p')),
        'why red?',
      );
      expect(telegramTurnText(_message(text: 'hi')), 'hi');
    });

    test('a file over the bot limit says how to send it instead, rather than '
        'asking for a retry that fails the same way', () {
      const tooBig = TelegramRefused(400, 'Bad Request: file is too big');
      const offline = TelegramUnreachable('no network');

      expect(telegramPictureFailure(tooBig), contains('as a photo'));
      expect(telegramPictureFailure(offline), contains('Try sending it again'));
    });
  });

  group('fetching the picture', () {
    test('plain text fetches nothing and attaches nothing', () async {
      final files = _Files();

      final result = await telegramPicturesOf(
        files,
        _message(text: 'hi'),
        log: const NoopAppLog(),
      );

      expect(result.pictures, isEmpty);
      expect(result.problem, isNull);
      expect(files.asked, isEmpty);
    });

    test('a picture is fetched by the id Telegram gave and attached under '
        'its own name, which is how its format is told', () async {
      final files = _Files(file: _file('file_7.jpg'));

      final result = await telegramPicturesOf(
        files,
        _message(pictureId: 'p7'),
        log: const NoopAppLog(),
      );

      expect(files.asked, ['p7']);
      expect(result.problem, isNull);
      expect(result.pictures.single.filename, 'file_7.jpg');
      expect(result.pictures.single.bytes, [1, 2, 3]);
    });

    test('a format Grid does not read is turned away with a way round it, '
        'not sent to a model that would fail on it', () async {
      final result = await telegramPicturesOf(
        _Files(file: _file('IMG_0001.HEIC')),
        _message(pictureId: 'p'),
        log: const NoopAppLog(),
      );

      expect(result.pictures, isEmpty);
      expect(result.problem, kTelegramPictureUnreadable);
    });

    test(
      'a file whose own name says Grid cannot read it is turned away '
      'unfetched — an iPhone original is tens of megabytes of HEIC',
      () async {
        final files = _Files(file: _file('file_9.heic'));

        final result = await telegramPicturesOf(
          files,
          _message(pictureId: 'p', pictureName: 'IMG_0001.HEIC'),
          log: const NoopAppLog(),
        );

        expect(files.asked, isEmpty);
        expect(result.problem, kTelegramPictureUnreadable);
      },
    );

    test('a picture Telegram would not hand over is explained to its sender '
        'instead of answered without it', () async {
      final result = await telegramPicturesOf(
        _Files(failure: const TelegramRefused(400, 'file is too big')),
        _message(text: 'look', pictureId: 'p'),
        log: const NoopAppLog(),
      );

      expect(result.pictures, isEmpty);
      expect(result.problem, contains('20 MB'));
    });
  });
}
