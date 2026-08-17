// Manual probe: drives the .docx patcher over a hand-built Word file to confirm
// what a save preserves and what it flattens. Run:
//   dart run tool/docx_roundtrip_check.dart
// Not a unit test — §8 keeps test/ to the grid and the agents — but this is the
// one piece of Docs that can damage a user's file, so it gets something to run
// after a change rather than nothing. Alongside `hermes_acp_probe.dart`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docx_creator/docx_creator.dart';
import 'package:grid_app/features/office/logic/docx_edit.dart';

const _document = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t>Title here</w:t></w:r></w:p><w:p><w:r><w:t xml:space="preserve">Hello </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>world</w:t></w:r></w:p><w:p><w:hyperlink r:id="rId1"><w:r><w:rPr><w:color w:val="0000FF"/></w:rPr><w:t>a link</w:t></w:r></w:hyperlink></w:p><w:p><w:r><w:tab/><w:t>tabbed</w:t></w:r></w:p><w:p/><w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body></w:document>''';

Uint8List _fixture() {
  final zip = Archive()
    ..add(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
    ..add(ArchiveFile.string('word/document.xml', _document))
    ..add(ArchiveFile.string('word/styles.xml', '<w:styles/>'));
  return ZipEncoder().encodeBytes(zip);
}

String _bodyOf(Uint8List bytes) => utf8.decode(
  ZipDecoder().decodeBytes(bytes).findFile('word/document.xml')!.readBytes()!,
);

var failures = 0;

void check(String what, Object? actual, Object? expected) {
  final ok = '$actual' == '$expected';
  if (!ok) failures++;
  stdout.writeln('${ok ? 'ok  ' : 'FAIL'} $what');
  if (!ok) {
    stdout.writeln('       expected: $expected\n       actual:   $actual');
  }
}

Future<void> main() async {
  final original = _fixture();
  final doc = DocxFile.open(original)!;
  check('reads one line per paragraph', doc.lines, [
    'Title here',
    'Hello world',
    'a link',
    '\ttabbed',
    '',
  ]);

  // 1. Edit one line in the middle.
  final edited = DocxFile.open(
    doc.save('Title here\nHello Grid\na link\n\ttabbed\n'),
  )!;
  check('edited line reads back', edited.lines[1], 'Hello Grid');
  check('other lines untouched', edited.lines, [
    'Title here',
    'Hello Grid',
    'a link',
    '\ttabbed',
    '',
  ]);
  final editedBody = _bodyOf(
    doc.save('Title here\nHello Grid\na link\n\ttabbed\n'),
  );
  check(
    'untouched heading keeps its XML',
    editedBody.contains(
      '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr><w:t>Title here</w:t></w:r></w:p>',
    ),
    true,
  );
  // The bold in "Hello **world**" is on the paragraph's *second* run, so it is
  // the documented casualty of retyping that paragraph. The heading, whose first
  // run carries the formatting, keeps both its style and its bold.
  final retitled = _bodyOf(
    doc.save('New title\nHello world\na link\n\ttabbed\n'),
  );
  check(
    "edited paragraph keeps its style and its first run's formatting",
    retitled.contains(
      '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr>'
      '<w:t xml:space="preserve">New title</w:t></w:r></w:p>',
    ),
    true,
  );
  check(
    'retyping a mixed paragraph flattens it to one run',
    editedBody.contains('<w:t xml:space="preserve">Hello Grid</w:t>') &&
        !editedBody.contains('<w:t xml:space="preserve">Hello </w:t>'),
    true,
  );
  check(
    'untouched hyperlink survives',
    editedBody.contains('<w:hyperlink r:id="rId1">'),
    true,
  );
  check('sectPr survives', editedBody.contains('<w:sectPr>'), true);
  check(
    'other zip entries survive',
    ZipDecoder()
        .decodeBytes(doc.save(doc.text))
        .files
        .map((f) => f.name)
        .toList(),
    ['[Content_Types].xml', 'word/document.xml', 'word/styles.xml'],
  );

  // 2. A line added in the middle takes the *look* of the paragraph above it —
  // its `pPr`, which is what makes Enter after a heading or a bullet behave.
  final added = _bodyOf(
    doc.save('Title here\na new heading\nHello world\na link\n\ttabbed\n'),
  );
  check(
    'added line inherits the paragraph style above it',
    added.contains(
      '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr>'
      '<w:t xml:space="preserve">a new heading</w:t></w:r></w:p>',
    ),
    true,
  );
  check(
    'added line reads back',
    DocxFile.open(
      doc.save('Title here\nHello world\na link\n\ttabbed\nadded line\n'),
    )!.lines,
    ['Title here', 'Hello world', 'a link', '\ttabbed', 'added line', ''],
  );

  // 3. A deleted line takes its paragraph with it.
  check(
    'deleted line is gone',
    DocxFile.open(doc.save('Title here\na link\n\ttabbed\n'))!.lines,
    ['Title here', 'a link', '\ttabbed', ''],
  );

  // 4. Emptying a line leaves the paragraph, not a stray run.
  check(
    'emptied line keeps its paragraph',
    DocxFile.open(doc.save('Title here\n\na link\n\ttabbed\n'))!.lines,
    ['Title here', '', 'a link', '\ttabbed', ''],
  );

  // 5. Retyping a hyperlink's line drops the emptied wrapper.
  final relinked = _bodyOf(
    doc.save('Title here\nHello world\nplain now\n\ttabbed\n'),
  );
  check(
    'emptied hyperlink wrapper removed',
    relinked.contains('<w:hyperlink'),
    false,
  );

  // 6. Saving twice with the same text is the same file.
  check(
    'save is idempotent',
    _bodyOf(doc.save('Title here\nHello Grid\na link\n\ttabbed\n')) ==
        _bodyOf(doc.save('Title here\nHello Grid\na link\n\ttabbed\n')),
    true,
  );

  // 7. Not a docx at all.
  check(
    'rejects a non-zip',
    DocxFile.open(Uint8List.fromList([1, 2, 3])),
    null,
  );

  // 8. The blank document "New" makes is one this patcher can open and write
  // back. Two packages have to agree here — docx_creator generates the file and
  // docx_edit patches it — so a version bump to either can break New without
  // touching a line of our own code.
  final blank = File('${Directory.systemTemp.path}/grid-blank-probe.docx');
  await DocxExporter().exportToFile(docx().p('').build(), blank.path);
  final made = DocxFile.open(await blank.readAsBytes());
  check('a generated blank document opens', made != null, true);
  check('and holds one empty paragraph', made?.lines, ['']);
  check(
    'and takes typed text back',
    DocxFile.open(made!.save('Hello from Grid'))?.lines,
    ['Hello from Grid'],
  );
  await blank.delete();

  stdout.writeln(failures == 0 ? '\nALL PASS' : '\n$failures FAILED');
}
