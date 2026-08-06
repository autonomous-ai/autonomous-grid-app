import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/file_attachments.dart';

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
        imageBudget: 4,
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
        imageBudget: 4,
        fileBudget: 5,
      );

      expect(added.images.single.filename, 'shot.png');
      expect(added.files, isEmpty);
    });

    test('a folder is mentioned by path, since the assistant can still look '
        'inside it', () async {
      final added = await readAttachments(
        [dir.path],
        imageBudget: 4,
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
        imageBudget: 4,
        fileBudget: 5,
      );

      // No reader on this platform under `flutter test` — the chip still names
      // it, and [ChatFile.promptBlock] says the text couldn't be read.
      expect(added.files.single.name, 'scan.pdf');
      expect(added.files.single.isReadable, isFalse);
    });

    test('what does not fit is reported, not silently dropped', () async {
      final first = await write('one.txt', 'one');
      final second = await write('two.txt', 'two');

      final added = await readAttachments(
        [first, second],
        imageBudget: 4,
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
