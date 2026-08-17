/// Reading the words of a `.docx` and putting edited ones back, without
/// disturbing the rest of the file.
///
/// A `.docx` is a zip of XML parts. The prose lives in one of them —
/// `word/document.xml`, a run of `<w:p>` paragraphs — while styles, fonts,
/// images, headers and numbering sit in parts this module never opens. So a save
/// is a **patch, not a conversion**: only the paragraphs whose text actually
/// changed are rewritten, every other paragraph keeps its own XML, and every
/// other zip entry is copied through unchanged. That is what lets a document
/// come out of a plain-text editor still looking like the document that went in
/// — Word never notices it was opened.
///
/// Pure: bytes in, bytes out, no filesystem. The patch can be reasoned about
/// without a real file on disk.
///
/// **What editing a paragraph does cost.** A paragraph the user changed is
/// rebuilt from one run, so formatting that varied *inside* that paragraph (a
/// bold word mid-sentence) comes back in the formatting of its first run, and a
/// soft line break inside it (Shift+Enter) reads and returns as a space.
/// Paragraphs the user didn't touch are not rewritten at all and keep both.
///
/// TODO(BE): that flattening is the honest ceiling of a text-only editor, and it
/// is silent — the user sees no warning that a mixed-format paragraph they
/// retyped came back plain. Editing runs individually means the editor has to
/// know about runs, which is the next feature rather than a tweak to this file.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// The part of the zip that holds the prose. Everything else is copied through.
const _bodyPart = 'word/document.xml';

/// What a run may carry that counts as the paragraph's words.
const _textChildren = {'t', 'tab', 'br'};

/// Elements that only exist to wrap runs, and mean nothing once emptied — a
/// hyperlink with no run left inside it is an underline over a gap.
const _runWrappers = {'hyperlink', 'smartTag', 'sdtContent', 'ins', 'del'};

/// A `.docx` opened for text editing: the zip it came from, and its paragraphs
/// as one line each.
///
/// Immutable, and deliberately the **baseline** rather than a live document:
/// [save] patches the file as it was opened every time, so saving twice with the
/// same text gives the same bytes as saving once.
class DocxFile {
  const DocxFile._(this._zip, this._bodyXml, this.lines);

  final Archive _zip;

  /// `word/document.xml` as it was read. Re-parsed per [save] because applying a
  /// patch mutates the tree, and the second save has to start from the file's
  /// own words rather than from the first save's result.
  final String _bodyXml;

  /// The document's paragraphs, one line each, in the order Word lays them out.
  final List<String> lines;

  /// Opens [bytes] as a Word document — or null when it isn't one this app can
  /// edit: not a zip, no `word/document.xml` inside, malformed XML, or a body
  /// with no paragraphs at all (a `.doc` renamed to `.docx`, a download that
  /// arrived truncated).
  ///
  /// Null rather than an empty document on purpose: an editor opened on
  /// something this module can't map back to paragraphs would take the user's
  /// typing and drop it on save.
  static DocxFile? open(Uint8List bytes) {
    final zip = _unzip(bytes);
    if (zip == null) return null;
    final xml = _bodyXmlOf(zip);
    if (xml == null) return null;
    final body = _parse(xml);
    if (body == null) return null;
    final paragraphs = _paragraphsOf(body);
    if (paragraphs.isEmpty) return null;
    return DocxFile._(zip, xml, [
      for (final paragraph in paragraphs) _paragraphLine(paragraph),
    ]);
  }

  /// The document as the editor shows it: one line per paragraph.
  String get text => lines.join('\n');

  /// The whole file with [edited] as its text — the same zip, with only the
  /// paragraphs that differ from [lines] touched.
  Uint8List save(String edited) {
    // Can't fail: this is the string [open] already parsed.
    final body = XmlDocument.parse(_bodyXml);
    _applyLines(body, lines, edited.split('\n'));
    final out = Archive();
    for (final file in _zip.files) {
      out.add(
        file.name == _bodyPart
            ? ArchiveFile.bytes(_bodyPart, utf8.encode(body.toXmlString()))
            : file,
      );
    }
    return ZipEncoder().encodeBytes(out);
  }
}

/// Every `<w:p>` in the document, in the order their words read — paragraphs
/// inside tables and text boxes included, because that is where the words are.
///
/// The one list both reading and writing walk, so a line is always patched back
/// onto the paragraph it came from.
List<XmlElement> _paragraphsOf(XmlDocument body) =>
    body.findAllElements('p', namespaceUri: '*').toList();

/// One paragraph as exactly one editor line.
///
/// Deliberately *not* the chat attachment reader's `docxText`, which turns a
/// soft line break into a newline: here a newline is what separates one
/// paragraph from the next, so a paragraph that produced two lines would slide
/// every following paragraph's text onto the wrong paragraph on save. A soft
/// break reads as a space instead.
String _paragraphLine(XmlElement paragraph) {
  final buffer = StringBuffer();
  for (final node in paragraph.descendants.whereType<XmlElement>()) {
    switch (node.name.local) {
      case 't':
        buffer.write(node.innerText);
      case 'tab':
        buffer.write('\t');
      case 'br':
        buffer.write(' ');
    }
  }
  return buffer.toString();
}

/// Moves the document from [from] to [to], touching as little as possible.
///
/// Lines shared at the top and the bottom of the two lists are left completely
/// alone — their paragraphs keep their XML byte for byte. Only the run between
/// the two is rewritten, which is why editing the last line of a hundred-page
/// document rewrites one paragraph rather than a hundred.
void _applyLines(XmlDocument body, List<String> from, List<String> to) {
  // Paragraph count and line count agree by construction: [from] was read off
  // this same list, from this same string.
  final paragraphs = _paragraphsOf(body);
  final head = _sharedHead(from, to);
  final tail = _sharedTail(from, to, head);
  final oldCount = from.length - head - tail;
  final newCount = to.length - head - tail;
  final shared = oldCount < newCount ? oldCount : newCount;

  for (var i = 0; i < shared; i++) {
    _setParagraphText(paragraphs[head + i], to[head + i]);
  }
  _insertLines(
    paragraphs,
    head,
    shared,
    to.sublist(head + shared, head + newCount),
  );
  for (var i = shared; i < oldCount; i++) {
    paragraphs[head + i].remove();
  }
}

/// How many lines the two versions share from the top.
int _sharedHead(List<String> from, List<String> to) {
  final limit = from.length < to.length ? from.length : to.length;
  var count = 0;
  while (count < limit && from[count] == to[count]) {
    count++;
  }
  return count;
}

/// How many lines they share from the bottom, never overlapping the [head] the
/// two already share — a line can't be both.
int _sharedTail(List<String> from, List<String> to, int head) {
  var count = 0;
  while (count < from.length - head &&
      count < to.length - head &&
      from[from.length - 1 - count] == to[to.length - 1 - count]) {
    count++;
  }
  return count;
}

/// Adds the lines the user typed that have no paragraph yet.
///
/// Each one is a **copy of the paragraph it follows**, so pressing Enter at the
/// end of a bulleted list adds another bullet and Enter after a heading does not
/// make the new line a heading's twin somewhere else in the document. Typed
/// above everything, they go in before the first paragraph instead.
void _insertLines(
  List<XmlElement> paragraphs,
  int head,
  int shared,
  List<String> added,
) {
  if (added.isEmpty) return;
  // The paragraph the new ones copy: the last one this edit rewrote, else the
  // one just above the edited run, else the document's first.
  var anchor = switch ((shared > 0, head > 0)) {
    (true, _) => paragraphs[head + shared - 1],
    (_, true) => paragraphs[head - 1],
    _ => paragraphs.first,
  };
  var before = shared == 0 && head == 0;
  for (final line in added) {
    final clone = anchor.copy();
    _setParagraphText(clone, line);
    final siblings = anchor.siblings;
    siblings.insert(siblings.indexOf(anchor) + (before ? 0 : 1), clone);
    anchor = clone;
    before = false;
  }
}

/// Puts [text] in the paragraph, keeping the paragraph itself — its style, its
/// list numbering, and its first run's character formatting.
void _setParagraphText(XmlElement paragraph, String text) {
  final runs = _textRuns(paragraph);
  // Where the replacement goes, measured before anything is removed: nothing
  // ahead of this point is touched, so the index stays true afterwards.
  //
  // The paragraph's *own* child that carried the first run — the run, or the
  // hyperlink around it. Beside that child rather than inside it, so a line that
  // began with a link doesn't come back as a line that is one.
  final at = runs.isEmpty
      ? paragraph.children.length
      : paragraph.children.indexOf(_childHolding(paragraph, runs.first));
  final style = runs.isEmpty ? null : _runStyle(runs.first);
  final wrappers = {for (final run in runs) run.parent};

  for (final run in runs) {
    run.remove();
  }
  for (final wrapper in wrappers) {
    if (wrapper is XmlElement &&
        _runWrappers.contains(wrapper.name.local) &&
        wrapper.childElements.isEmpty) {
      wrapper.remove();
    }
  }
  if (text.isEmpty) return;
  paragraph.children.insert(at, _buildRun(paragraph.name.prefix, style, text));
}

/// The runs carrying the paragraph's words — a `<w:r>` holding text, a tab or a
/// line break. A run holding only a field code, a bookmark or a picture is left
/// where it is, so an inline image survives its paragraph being retyped.
List<XmlElement> _textRuns(XmlElement paragraph) => [
  for (final node in paragraph.descendants.whereType<XmlElement>())
    if (node.name.local == 'r' && _carriesText(node)) node,
];

bool _carriesText(XmlElement run) {
  for (final child in run.childElements) {
    if (_textChildren.contains(child.name.local)) return true;
  }
  return false;
}

/// The paragraph's own child that [run] sits under — the run itself when it is a
/// direct child, otherwise the wrapper (a hyperlink, a tracked insertion).
XmlNode _childHolding(XmlElement paragraph, XmlElement run) {
  XmlNode node = run;
  while (node.parent != null && node.parent != paragraph) {
    node = node.parent!;
  }
  return node;
}

/// A copy of the run's `<w:rPr>` — the bold/size/colour the replacement should
/// keep. Null when the run had none, which means the paragraph's style decides.
XmlElement? _runStyle(XmlElement run) {
  for (final child in run.childElements) {
    if (child.name.local == 'rPr') return child.copy();
  }
  return null;
}

/// One run carrying [text], in [style] if the run it replaces had one.
///
/// Tabs come back as `<w:tab/>` rather than as a tab character, because Word
/// ignores whitespace inside `<w:t>` beyond a single space.
XmlElement _buildRun(String? prefix, XmlElement? style, String text) {
  final children = <XmlNode>[?style];
  final parts = text.split('\t');
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) children.add(XmlElement(XmlName.parts('tab', prefix: prefix)));
    if (parts[i].isEmpty) continue;
    children.add(
      XmlElement(
        XmlName.parts('t', prefix: prefix),
        [
          // Without this Word trims the run's leading and trailing spaces, which
          // is how "Dear  Bob" comes back as "DearBob" once the space between
          // two runs is the only thing holding them apart.
          XmlAttribute(XmlName.parts('space', prefix: 'xml'), 'preserve'),
        ],
        [XmlText(parts[i])],
      ),
    );
  }
  return XmlElement(XmlName.parts('r', prefix: prefix), const [], children);
}

String? _bodyXmlOf(Archive zip) {
  final bytes = zip.findFile(_bodyPart)?.readBytes();
  if (bytes == null) return null;
  return utf8.decode(bytes, allowMalformed: true);
}

XmlDocument? _parse(String xml) {
  try {
    return XmlDocument.parse(xml);
  } on XmlException {
    return null;
  }
}

/// The zip inside the file — null when it isn't one.
Archive? _unzip(Uint8List bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } on Object {
    return null;
  }
}
