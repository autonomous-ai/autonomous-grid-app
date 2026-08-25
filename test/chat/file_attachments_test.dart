import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/file_attachments.dart';
import 'package:grid_app/features/playground/logic/image_budget.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('grid_attachments_test');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<String> write(String name, String content) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString(content);
    return file.path;
  }

  group('sorting what was dropped', () {
    test('a document arrives with its text read, so the model gets the '
        'content and the agent gets the path', () async {
      final path = await write('notes.txt', 'Remember the milk.');

      final added = await readAttachments(
        [path],
        imageBytesBudget: kImagePayloadBudget,
        fileBudget: 5,
      );

      expect(added.files.single.name, 'notes.txt');
      expect(added.files.single.text, 'Remember the milk.');
      expect(added.files.single.path, path);
      expect(added.paths, isEmpty);
      expect(added.overflow, isEmpty);
    });

    test('a picture becomes an attachment rather than a path in the message '
        'text', () async {
      final path = '${dir.path}/shot.png';
      // Not a real PNG — nothing here decodes it, and the routing is what
      // matters: an image goes to the vision attachments, not to the files.
      await File(path).writeAsBytes([1, 2, 3]);

      final added = await readAttachments(
        [path],
        imageBytesBudget: kImagePayloadBudget,
        fileBudget: 5,
      );

      expect(added.images.single.filename, 'shot.png');
      expect(added.files, isEmpty);
    });

    test('a folder is mentioned by path, since the assistant can still look '
        'inside it', () async {
      final added = await readAttachments(
        [dir.path],
        imageBytesBudget: kImagePayloadBudget,
        fileBudget: 5,
      );

      expect(added.paths, [dir.path]);
      expect(added.files, isEmpty);
    });

    test('a file the app cannot read still attaches, so the assistant is told '
        'it exists', () async {
      final path = '${dir.path}/scan.pdf';
      await File(path).writeAsString('%PDF-1.7 no text layer');

      final added = await readAttachments(
        [path],
        imageBytesBudget: kImagePayloadBudget,
        fileBudget: 5,
      );

      // No reader on this platform under `flutter test` — the chip still names
      // it, and [ChatFile.promptBlock] says the text couldn't be read.
      expect(added.files.single.name, 'scan.pdf');
      expect(added.files.single.isReadable, isFalse);
    });

    test('a message takes as many pictures as fit the wire, so a fifth '
        'screenshot is not turned away for being the fifth', () async {
      final shots = <String>[];
      for (var i = 0; i < 8; i++) {
        final path = '${dir.path}/shot$i.png';
        await File(path).writeAsBytes([1, 2, 3]);
        shots.add(path);
      }

      final added = await readAttachments(
        shots,
        imageBytesBudget: kImagePayloadBudget,
        fileBudget: 5,
      );

      expect(added.images.length, 8);
      expect(added.overflow, isEmpty);
    });

    test('a picture with no budget left to spend is reported rather than '
        'quietly left off the message', () async {
      final path = '${dir.path}/shot.png';
      await File(path).writeAsBytes([1, 2, 3]);

      final added = await readAttachments(
        [path],
        imageBytesBudget: 0,
        fileBudget: 5,
      );

      expect(added.images, isEmpty);
      expect(added.overflow, ['shot.png']);
    });

    test('a picture crowded out by a nearly full message is reported as '
        'overflow, not as a picture the user has to crop', () async {
      final path = '${dir.path}/shot.png';
      await File(path).writeAsBytes([1, 2, 3, 4, 5]);

      final added = await readAttachments(
        [path],
        // Room left, but less than these five bytes — and nothing here decodes
        // a fake PNG, so shrinking cannot rescue it either.
        imageBytesBudget: 2,
        fileBudget: 5,
      );

      expect(added.overflow, ['shot.png']);
      expect(added.oversized, isEmpty);
    });

    test('what does not fit is reported, not silently dropped', () async {
      final first = await write('one.txt', 'one');
      final second = await write('two.txt', 'two');

      final added = await readAttachments(
        [first, second],
        imageBytesBudget: kImagePayloadBudget,
        fileBudget: 1,
      );

      expect(added.files.single.name, 'one.txt');
      expect(added.overflow, ['two.txt']);
      expect(attachmentOverflowMessage(added.overflow), contains('two.txt'));
    });
  });

  group('what to say about overflow', () {
    test('nothing to say when everything fit', () {
      expect(attachmentOverflowMessage(const []), isNull);
    });

    test('counts the rest so the user knows how much was left behind', () {
      final said = attachmentOverflowMessage(['a.txt', 'b.txt', 'c.txt'])!;

      expect(said, contains('a.txt'));
      expect(said, contains('2 more'));
    });
  });
}
