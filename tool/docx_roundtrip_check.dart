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
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t>Title here</w:t></w:r></w:p><w:p><w:r><w:t xml:space="preserve">Hello </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>world</w:t></w:r></w:p><w:p><w:hyperlink r:id="rId1"><w:r><w:rPr><w:color w:val="0000FF"/></w:rPr><w:t>a link</w:t></w:r></w:hyperlink></w:p><w:p><w:r><w:tab/><w:t>tabbed</w:t></w:r></w:p><w:p><w:r><w:t>one</w:t><w:br/><w:t>two</w:t></w:r></w:p><w:p/><w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body></w:document>''';

/// The fixture's paragraphs, as the editor sees them. The fifth is one paragraph
/// holding a soft break — the shape a real document uses for a run of bullets
/// typed with Shift+Enter, and the one that used to come out as a single
/// run-together line.
const _asOpened = [
  'Title here',
  'Hello world',
  'a link',
  '\ttabbed',
  'one\ntwo',
  '',
];

/// [_asOpened] with paragraph 1 retyped — the everyday edit.
const _edited = [
  'Title here',
  'Hello Grid',
  'a link',
  '\ttabbed',
  'one\ntwo',
  '',
];

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
  final doc = DocxFile.open(_fixture())!;
  check('reads one line per paragraph', doc.lines, _asOpened);
  check('a soft break stays inside its paragraph', doc.lines[4], 'one\ntwo');

  // 1. Edit one paragraph in the middle.
  final edited = DocxFile.open(doc.save(_edited))!;
  check('edited line reads back', edited.lines[1], 'Hello Grid');
  check('other lines untouched', edited.lines, _edited);

  final editedBody = _bodyOf(doc.save(_edited));
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
  final retitled = _bodyOf(doc.save(['New title', ..._asOpened.skip(1)]));
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
        .decodeBytes(doc.save(doc.lines))
        .files
        .map((f) => f.name)
        .toList(),
    ['[Content_Types].xml', 'word/document.xml', 'word/styles.xml'],
  );

  // 2. A soft break the user typed is written back as one, and a paragraph
  // retyped around its break keeps both halves.
  final broken = doc.save([..._asOpened.take(4), 'first\nsecond\nthird', '']);
  check(
    'a typed soft break is written as w:br',
    _bodyOf(broken).contains(
      '<w:t xml:space="preserve">first</w:t><w:br/>'
      '<w:t xml:space="preserve">second</w:t><w:br/>'
      '<w:t xml:space="preserve">third</w:t>',
    ),
    true,
  );
  check(
    'and reads back as one paragraph, not three',
    DocxFile.open(broken)!.lines,
    [..._asOpened.take(4), 'first\nsecond\nthird', ''],
  );
  check(
    'a tab and a break keep their order',
    _bodyOf(doc.save([..._asOpened.take(4), 'a\tb\nc', ''])).contains(
      '<w:t xml:space="preserve">a</w:t><w:tab/>'
      '<w:t xml:space="preserve">b</w:t><w:br/>'
      '<w:t xml:space="preserve">c</w:t>',
    ),
    true,
  );

  // 3. A paragraph added in the middle takes the *look* of the one above it —
  // its `pPr`, which is what makes Enter after a heading or a bullet behave.
  final added = _bodyOf(
    doc.save(['Title here', 'a new heading', ..._asOpened.skip(1)]),
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
    DocxFile.open(doc.save([..._asOpened, 'added line']))!.lines,
    [..._asOpened, 'added line'],
  );

  // 4. A deleted paragraph takes its element with it.
  check(
    'deleted line is gone',
    DocxFile.open(doc.save(['Title here', ..._asOpened.skip(2)]))!.lines,
    ['Title here', ..._asOpened.skip(2)],
  );

  // 5. Emptying a paragraph leaves the paragraph, not a stray run.
  check(
    'emptied line keeps its paragraph',
    DocxFile.open(doc.save(['Title here', '', ..._asOpened.skip(2)]))!.lines,
    ['Title here', '', ..._asOpened.skip(2)],
  );

  // 6. Retyping a hyperlink's line drops the emptied wrapper.
  check(
    'emptied hyperlink wrapper removed',
    _bodyOf(
      doc.save([
        'Title here',
        'Hello world',
        'plain now',
        ..._asOpened.skip(3),
      ]),
    ).contains('<w:hyperlink'),
    false,
  );

  // 7. Saving twice with the same text is the same file.
  check(
    'save is idempotent',
    _bodyOf(doc.save(_edited)) == _bodyOf(doc.save(_edited)),
    true,
  );

  // 8. Not a docx at all.
  check(
    'rejects a non-zip',
    DocxFile.open(Uint8List.fromList([1, 2, 3])),
    null,
  );

  // 9. The blank document "New" makes is one this patcher can open and write
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
    DocxFile.open(made!.save(['Hello from Grid']))?.lines,
    ['Hello from Grid'],
  );
  await blank.delete();

  stdout.writeln(failures == 0 ? '\nALL PASS' : '\n$failures FAILED');
}
