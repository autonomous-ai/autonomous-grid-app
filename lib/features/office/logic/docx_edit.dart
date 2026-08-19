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
/// bold word mid-sentence) comes back in the formatting of its first run.
/// Paragraphs the user didn't touch are not rewritten at all and keep theirs.
/// Tabs and soft line breaks *do* survive: they read as `\t` and `\n` and are
/// written back as `<w:tab/>` and `<w:br/>`.
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

import 'docx_format.dart';
import 'docx_paragraph_style.dart';
import 'docx_style_write.dart';

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
  const DocxFile._(
    this._zip,
    this._bodyXml,
    this.lines,
    this.formats,
    this.pageWidthPx,
  );

  /// How wide this document's pages are, in logical pixels.
  ///
  /// Read here because the walk is already open, and the editor draws its sheet
  /// at it: a document is laid out for the paper it was written on — A4 is 794px
  /// where US Letter is 816, and text set for one reads wrong at the other's
  /// measure.
  final double pageWidthPx;

  final Archive _zip;

  /// `word/document.xml` as it was read. Re-parsed per [save] because applying a
  /// patch mutates the tree, and the second save has to start from the file's
  /// own words rather than from the first save's result.
  final String _bodyXml;

  /// The document's paragraphs, one line each, in the order Word lays them out.
  final List<String> lines;

  /// How each of those paragraphs looks, by the same index.
  ///
  /// Read in the same pass as [lines] — see `docx_format.dart` for why that
  /// matters and how shallow it deliberately is.
  final List<DocxLineFormat> formats;

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
    final styles = _partRootOf(zip, 'word/styles.xml');
    return DocxFile._(
      zip,
      xml,
      [for (final paragraph in paragraphs) _paragraphLine(paragraph)],
      // The same list, walked once more rather than parsed again: index i of one
      // is index i of the other by construction, which is what the Edit view
      // relies on to type into the paragraph it is pointing at.
      lineFormats(
        paragraphs,
        styles,
        body,
        media: _mediaOf(zip),
        numberingRoot: _partRootOf(zip, 'word/numbering.xml'),
      ),
      _pageWidthPxOf(body),
    );
  }

  /// The whole file with [edited] as its paragraphs and [styles] laid over
  /// them — the same zip, with only what differs from [lines] touched.
  ///
  /// A list rather than one string split on newlines: a paragraph may contain a
  /// newline of its own (a soft break), so only the caller knows where one
  /// paragraph ends and the next begins.
  ///
  /// [styles] is one entry per paragraph of [edited], null where the toolbar
  /// changed nothing. It is applied **after** the text, and by index into the
  /// document as it then stands — which is what makes a formatted paragraph
  /// that was also split or deleted land on the right `w:p` without this having
  /// to track indices through the diff.
  Uint8List save(
    List<String> edited, {
    List<DocxParagraphStyle?> styles = const [],
  }) {
    // Can't fail: this is the string [open] already parsed.
    final body = XmlDocument.parse(_bodyXml);
    _applyLines(body, lines, edited);
    _applyStyles(body, styles);
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

/// Lays the toolbar's changes over the paragraphs the text pass left behind.
///
/// Read fresh rather than reusing the list the text pass held: that pass may
/// have inserted or removed a `w:p`, and index 7 of the document afterwards is
/// what index 7 of the editor is showing. A paragraph with no change is not
/// touched at all — [applyParagraphStyle] returns on an empty style, so a save
/// with nothing formatted writes byte-identical XML to one from before this
/// existed.
void _applyStyles(XmlDocument body, List<DocxParagraphStyle?> styles) {
  if (styles.isEmpty) return;
  final paragraphs = _paragraphsOf(body);
  final count = styles.length < paragraphs.length
      ? styles.length
      : paragraphs.length;
  for (var i = 0; i < count; i++) {
    final style = styles[i];
    if (style != null) applyParagraphStyle(paragraphs[i], style);
  }
}

/// Every `<w:p>` in the document, in the order their words read — paragraphs
/// inside tables and text boxes included, because that is where the words are.
///
/// The one list both reading and writing walk, so a line is always patched back
/// onto the paragraph it came from.
List<XmlElement> _paragraphsOf(XmlDocument body) =>
    body.findAllElements('p', namespaceUri: '*').toList();

/// One paragraph as one editor line — which may itself hold newlines.
///
/// A `w:br` is a soft line break (Shift+Enter), and it comes back as `\n`.
/// It used to come back as a space, to keep one paragraph on one line: the
/// editor's text was a single string joined by newlines, so a paragraph
/// producing two lines would have slid every following paragraph's text onto
/// the wrong paragraph on save.
///
/// Real documents settled that. A file where a whole numbered section is *one*
/// paragraph with soft breaks between its bullets — which is what Word gives
/// you for Shift+Enter — came out as one unreadable block of run-together
/// sentences. The lines are a `List<String>` now precisely so a paragraph can
/// hold its own breaks without the list losing count of paragraphs.
String _paragraphLine(XmlElement paragraph) {
  final buffer = StringBuffer();
  for (final node in paragraph.descendants.whereType<XmlElement>()) {
    switch (node.name.local) {
      case 't':
        buffer.write(node.innerText);
      case 'tab':
        buffer.write('\t');
      case 'br':
        buffer.write('\n');
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
/// Tabs and newlines come back as `<w:tab/>` and `<w:br/>` rather than as
/// characters: Word ignores whitespace inside `<w:t>` beyond a single space, so
/// a paragraph's own line breaks would simply vanish on the way out. That is the
/// other half of reading `w:br` as `\n` — a soft break survives a round trip
/// through the editor instead of being flattened by it.
XmlElement _buildRun(String? prefix, XmlElement? style, String text) {
  final children = <XmlNode>[?style];
  final parts = _splitKeepingBreaks(text);
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) {
      children.add(
        XmlElement(
          XmlName.parts(parts[i].afterBreak ? 'br' : 'tab', prefix: prefix),
        ),
      );
    }
    if (parts[i].text.isEmpty) continue;
    children.add(
      XmlElement(
        XmlName.parts('t', prefix: prefix),
        [
          // Without this Word trims the run's leading and trailing spaces, which
          // is how "Dear  Bob" comes back as "DearBob" once the space between
          // two runs is the only thing holding them apart.
          XmlAttribute(XmlName.parts('space', prefix: 'xml'), 'preserve'),
        ],
        [XmlText(parts[i].text)],
      ),
    );
  }
  return XmlElement(XmlName.parts('r', prefix: prefix), const [], children);
}

/// A stretch of a paragraph's text, and which mark ended the one before it.
typedef _RunPart = ({String text, bool afterBreak});

/// Splits [text] on tabs and newlines, remembering which was which.
///
/// One pass over both, rather than splitting on one and then the other: the two
/// have to keep their order, and `"a\tb\nc"` written back with its tab and its
/// break the wrong way round is a paragraph that reads differently than it did.
List<_RunPart> _splitKeepingBreaks(String text) {
  final parts = <_RunPart>[];
  var start = 0;
  var afterBreak = false;
  for (var i = 0; i < text.length; i++) {
    final mark = text[i];
    if (mark != '\t' && mark != '\n') continue;
    parts.add((text: text.substring(start, i), afterBreak: afterBreak));
    afterBreak = mark == '\n';
    start = i + 1;
  }
  parts.add((text: text.substring(start), afterBreak: afterBreak));
  return parts;
}

/// The page width from the body's trailing `w:sectPr`, in logical pixels.
///
/// US Letter when the document doesn't say — Word's own default, and the width
/// most documents that omit `w:pgSz` were written at.
double _pageWidthPxOf(XmlDocument body) {
  const letterTwips = 12240;
  final sections = body.findAllElements('sectPr', namespaceUri: '*').toList();
  final size = sections.isEmpty
      ? null
      : sections.last.childElements
            .where((e) => e.name.local == 'pgSz')
            .firstOrNull;
  final twips = int.tryParse(
    size?.attributes
            .where((a) => a.name.local == 'w')
            .firstOrNull
            ?.value
            .trim() ??
        '',
  );
  return (twips ?? letterTwips) / 15;
}

/// Every picture the document points at, by the relationship id that points at
/// it.
///
/// Read here, with the zip already open, so the Edit view can draw the pictures
/// rather than leave gaps where they are. Only the parts an `r:id` actually
/// names: a document's media folder can hold what nothing references, and
/// carrying those would be bytes in memory for nothing on screen.
Map<String, Uint8List> _mediaOf(Archive zip) {
  final rels = zip.findFile('word/_rels/document.xml.rels')?.readBytes();
  final root = rels == null
      ? null
      : _parse(utf8.decode(rels, allowMalformed: true))?.rootElement;
  if (root == null) return const {};
  final media = <String, Uint8List>{};
  for (final entry in root.childElements) {
    if (entry.name.local != 'Relationship') continue;
    final id = _attributeOf(entry, 'Id');
    final target = _attributeOf(entry, 'Target');
    if (id == null || target == null) continue;
    if (_attributeOf(entry, 'TargetMode') == 'External') continue;
    // Targets are relative to the part that owns them, so a document's
    // `media/image1.png` is `word/media/image1.png` in the archive.
    final path = target.startsWith('/')
        ? target.substring(1)
        : 'word/${target.replaceAll('../', '')}';
    final bytes = zip.findFile(path)?.readBytes();
    if (bytes != null) media[id] = bytes;
  }
  return media;
}

String? _attributeOf(XmlElement element, String local) {
  for (final attribute in element.attributes) {
    if (attribute.name.local == local) return attribute.value;
  }
  return null;
}

/// The root of one XML part, or null when the file hasn't got it — a document
/// with no styles or no numbering still opens; its paragraphs just draw at the
/// fallback size, or without markers.
XmlElement? _partRootOf(Archive zip, String path) {
  final bytes = zip.findFile(path)?.readBytes();
  if (bytes == null) return null;
  return _parse(utf8.decode(bytes, allowMalformed: true))?.rootElement;
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
