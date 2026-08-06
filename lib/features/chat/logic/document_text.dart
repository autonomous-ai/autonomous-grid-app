/// Pulls readable text out of the everyday office files people attach to a
/// message — Word, Excel, PowerPoint, and anything already written as text.
///
/// Pure and side-effect free: bytes in, text out. Reading the file off disk and
/// the one format that needs the operating system (PDF) live in
/// `file_attachments.dart`, so everything here can be tested without a
/// filesystem. The zipped-XML formats have their own module, `ooxml_text.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../playground/logic/chat_file.dart';
import 'ooxml_text.dart';

/// The file types the composer offers in its picker, beyond images.
///
/// Everything here either has a reader below or is a PDF (read by the operating
/// system). A type the app can't read is still attachable — the file goes to the
/// assistant by path — but offering it in the picker would promise more than
/// this list can keep, so the picker sticks to what usually works.
const List<String> kDocumentExtensions = [
  'pdf',
  'docx',
  'xlsx',
  'pptx',
  'txt',
  'md',
  'csv',
  'tsv',
  'json',
  'yaml',
  'yml',
  'xml',
  'html',
  'log',
  'rtf',
];

/// Text read out of a document, and whether the file ran on past it.
class DocumentText {
  const DocumentText(this.text, {this.truncated = false});

  final String text;
  final bool truncated;
}

/// The text inside [bytes], a file called [name] — or null when this build can't
/// read that kind of file (a PDF, a legacy `.doc`, a picture, an archive).
///
/// Null is not a failure to hide: the caller attaches the file by path anyway
/// and says so, since an agent with file tools may still be able to open it.
DocumentText? extractDocumentText(
  String name,
  Uint8List bytes, {
  int budget = kFileTextBudget,
}) {
  final text = switch (fileExtensionOf(name)) {
    'docx' => docxText(bytes),
    'xlsx' => xlsxText(bytes),
    'pptx' => pptxText(bytes),
    'rtf' => _fromRtf(bytes),
    // Read by the operating system, or by nothing at all: the old binary Office
    // formats and PDFs are not zipped XML, and guessing at them would return
    // mojibake dressed up as the user's document.
    'pdf' || 'doc' || 'xls' || 'ppt' || 'pages' || 'numbers' || 'key' => null,
    _ => _fromPlainText(bytes),
  };
  if (text == null) return null;
  return tidyAndCap(text, budget: budget);
}

/// Cleans [text] up and holds it to [budget] — the last step of every reader,
/// and the one the PDF reader (which gets its text from the operating system,
/// not from these bytes) joins the path at.
///
/// Null when nothing readable is left: an empty document and one the app failed
/// to read are the same thing to the person waiting for an answer about it.
DocumentText? tidyAndCap(String text, {int budget = kFileTextBudget}) {
  final tidy = _tidy(text);
  if (tidy.isEmpty) return null;
  return _capped(tidy, budget);
}

/// Anything already written as text — `.txt`, `.csv`, a `.dart` file dragged in
/// from a project — decided by the bytes rather than by the extension, so a file
/// type nobody listed still reaches the model as what it is.
///
/// A single NUL is enough to call it binary: no text file has one, and every
/// binary format that would otherwise squeeze through UTF-8 has plenty.
String? _fromPlainText(Uint8List bytes) {
  if (bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// Rich text: strip the control words and keep what was typed.
///
/// RTF is plain ASCII with `\command` markers and `{}` groups around them, so
/// dropping those leaves the document's own words — enough for a model to read,
/// without a parser for a format Word itself is retiring.
String? _fromRtf(Uint8List bytes) {
  final raw = _fromPlainText(bytes);
  if (raw == null || !raw.trimLeft().startsWith(r'{\rt')) return null;
  return raw
      // Escaped characters first, so a `\'e9` doesn't leave a stray `'e9`.
      .replaceAll(RegExp(r"\\'[0-9a-fA-F]{2}"), '')
      .replaceAll(RegExp(r'\\par[d]?\b'), '\n')
      .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d*\s?'), '')
      .replaceAll(RegExp(r'[{}]'), '');
}

/// Trailing spaces, stray carriage returns and runs of blank lines — noise every
/// extractor produces, and all of it costs prompt space.
String _tidy(String text) => text
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .split('\n')
    .map((line) => line.trimRight())
    .join('\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

/// [text] cut to [budget] characters, on a line break where there is one nearby
/// so the last line isn't sliced mid-word.
DocumentText _capped(String text, int budget) {
  if (text.length <= budget) return DocumentText(text);
  final head = text.substring(0, budget);
  final lastBreak = head.lastIndexOf('\n');
  final cut = lastBreak > budget ~/ 2 ? head.substring(0, lastBreak) : head;
  return DocumentText(cut, truncated: true);
}
