import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing_host/mobile_upload_store.dart';

/// The only place a paired phone puts bytes on this computer.
///
/// Every limit below is the reason this class exists rather than a `writeAsBytes`
/// at the call site, so each one is asserted: a cap nobody checks is a comment.
void main() {
  late Directory root;
  late MobileUploadStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('grid-phone-uploads');
    store = MobileUploadStore(directory: Directory('${root.path}/uploads'));
  });

  tearDown(() => root.deleteSync(recursive: true));

  String chunkOf(int bytes) => base64Encode(List.filled(bytes, 7));

  test('assembles a file from its pieces and hands it over once', () {
    final begun = store.begin(name: 'photo.jpg', sizeBytes: 300);
    expect(begun.id, isNotNull);

    expect(store.addChunk(begun.id!, chunkOf(200)), isNull);
    expect(store.addChunk(begun.id!, chunkOf(100)), isNull);

    final taken = store.take([begun.id!]);
    expect(taken.files, hasLength(1));
    expect(taken.files!.single.file.lengthSync(), 300);
    // Taken means gone: a second turn must not attach the same file again.
    expect(store.take([begun.id!]).problem, isNotNull);
  });

  test('refuses a file larger than a phone has any business sending, before '
      'a single byte is written', () {
    final begun = store.begin(name: 'huge.bin', sizeBytes: maxFileBytes + 1);

    expect(begun.id, isNull);
    expect(begun.problem, isNotNull);
  });

  test('refuses a chunk that would carry the file past what it declared, '
      'because a small declaration followed by an endless stream is the same '
      'attack as a large declaration', () {
    final begun = store.begin(name: 'a.bin', sizeBytes: 100);

    expect(store.addChunk(begun.id!, chunkOf(100)), isNull);
    expect(store.addChunk(begun.id!, chunkOf(1)), isNotNull);
  });

  test('refuses a piece bigger than one frame may carry, since the relay '
      'enforces its ceiling by ending the connection', () {
    final begun = store.begin(name: 'a.bin', sizeBytes: maxFileBytes);

    expect(store.addChunk(begun.id!, chunkOf(maxChunkBytes + 1)), isNotNull);
  });

  test('refuses to keep more uploads open than a person would ever start, so '
      'a phone cannot fill the disk with beginnings', () {
    for (var i = 0; i < maxOpen; i++) {
      expect(store.begin(name: 'f$i.bin', sizeBytes: 10).id, isNotNull);
    }

    expect(store.begin(name: 'one-too-many.bin', sizeBytes: 10).id, isNull);
  });

  test('never lets a name out of the folder — the phone picks it, so it is '
      'the one field an attacker controls', () {
    final begun = store.begin(name: '../../.ssh/authorized_keys', sizeBytes: 4);
    store.addChunk(begun.id!, chunkOf(4));

    final upload = store.take([begun.id!]).files!.single;

    // The name that travels into the chat, and the path the bytes landed at.
    // Both have to be inside the uploads folder; asserting only the first
    // would pass even if the file itself had been written over an ssh key.
    expect(upload.name, isNot(contains('/')));
    expect(upload.name, isNot(contains('..')));
    // No extension survives here at all: what follows the last dot is a path,
    // not a file type, and the rule keeps only a short alphanumeric one.
    expect(upload.name, isNot(contains('ssh')));
    expect(upload.name, isNot(contains('keys')));
    expect(upload.file.parent.path, endsWith('uploads'));
  });

  test('keeps the extension, because the computer decides picture-or-document '
      'by it and a photo that arrives nameless is attached as a file', () {
    final begun = store.begin(name: 'holiday.JPEG', sizeBytes: 4);
    expect(store.addChunk(begun.id!, chunkOf(4)), isNull);

    expect(store.take([begun.id!]).files!.single.name, endsWith('.jpeg'));
  });

  test('takes nothing at all when one of several is unfinished, since a turn '
      'answered about two of three attachments is answered about the wrong '
      'thing', () {
    final first = store.begin(name: 'a.png', sizeBytes: 4);
    final second = store.begin(name: 'b.png', sizeBytes: 4);
    store.addChunk(first.id!, chunkOf(4));

    final taken = store.take([first.id!, second.id!]);

    expect(taken.files, isNull);
    expect(taken.problem, isNotNull);
    // And the finished one is still available afterwards, not consumed by the
    // attempt that failed.
    expect(store.take([first.id!]).files, hasLength(1));
  });

  test('rejects a chunk that is not base64 rather than writing rubbish into '
      'the file', () {
    final begun = store.begin(name: 'a.bin', sizeBytes: 10);

    expect(store.addChunk(begun.id!, 'not base64!!'), isNotNull);
  });
}
