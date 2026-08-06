import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/document_text.dart';

/// Zips [entries] into an Office-style container, the way Word and Excel save.
Uint8List _zip(Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  group('a Word document', () {
    test('reads as one line per paragraph, so prose keeps its shape', () {
      final docx = _zip({
        'word/document.xml':
            '<?xml version="1.0"?>'
            '<w:document xmlns:w="http://schemas.openxmlformats.org/'
            'wordprocessingml/2006/main"><w:body>'
            '<w:p><w:r><w:t>Quarterly report</w:t></w:r></w:p>'
            '<w:p><w:r><w:t>Revenue was </w:t></w:r>'
            '<w:r><w:t>up 12%.</w:t></w:r></w:p>'
            '</w:body></w:document>',
      });

      final read = extractDocumentText('report.docx', docx);

      expect(read?.text, 'Quarterly report\nRevenue was up 12%.');
      expect(read?.truncated, isFalse);
    });

    test('a file that is not really a zip comes back unread, not garbled', () {
      final read = extractDocumentText('broken.docx', _bytes('not a zip'));

      expect(read, isNull);
    });
  });

  group('a spreadsheet', () {
    test('resolves shared strings so cells arrive as their words', () {
      final xlsx = _zip({
        'xl/workbook.xml':
            '<workbook xmlns="http://schemas.openxmlformats.org/'
            'spreadsheetml/2006/main"><sheets>'
            '<sheet name="Q3 revenue" sheetId="1"/></sheets></workbook>',
        'xl/sharedStrings.xml':
            '<sst xmlns="http://schemas.openxmlformats.org/'
            'spreadsheetml/2006/main">'
            '<si><t>Region</t></si><si><t>North</t></si></sst>',
        'xl/worksheets/sheet1.xml':
            '<worksheet xmlns="http://schemas.openxmlformats.org/'
            'spreadsheetml/2006/main"><sheetData>'
            '<row><c t="s"><v>0</v></c><c t="s"><v>1</v></c></row>'
            '<row><c><v>42</v></c></row>'
            '</sheetData></worksheet>',
      });

      final read = extractDocumentText('sales.xlsx', xlsx);

      // The sheet's own name heads it, so a model can say where a number came
      // from rather than calling everything "the spreadsheet".
      expect(read?.text, '--- Q3 revenue ---\nRegion\tNorth\n42');
    });
  });

  group('a slide deck', () {
    test('keeps slides in numeric order, not the zip’s alphabetical one', () {
      const ns =
          'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"';
      final pptx = _zip({
        'ppt/slides/slide10.xml':
            '<sld $ns><a:p><a:r><a:t>Tenth</a:t></a:r></a:p></sld>',
        'ppt/slides/slide2.xml':
            '<sld $ns><a:p><a:r><a:t>Second</a:t></a:r></a:p></sld>',
      });

      final read = extractDocumentText('deck.pptx', pptx);

      expect(read?.text, '--- Slide 2 ---\nSecond\n--- Slide 10 ---\nTenth');
    });
  });

  group('everything else', () {
    test(
      'a text file is read whatever its extension, so code attaches too',
      () {
        final read = extractDocumentText('main.dart', _bytes('void main() {}'));

        expect(read?.text, 'void main() {}');
      },
    );

    test('binary comes back unread rather than as mojibake', () {
      final read = extractDocumentText(
        'photo.raw',
        Uint8List.fromList([0x89, 0x50, 0x00, 0x01, 0x02]),
      );

      expect(read, isNull);
    });

    test(
      'an empty file reads as nothing to send, not as an empty document',
      () {
        expect(extractDocumentText('notes.txt', _bytes('   \n\n ')), isNull);
      },
    );

    test('a PDF is left to the operating system rather than guessed at', () {
      expect(extractDocumentText('scan.pdf', _bytes('%PDF-1.7 ...')), isNull);
    });
  });

  group('the budget', () {
    test('a long file is cut and says so, so nothing is silently dropped', () {
      final long = List.filled(50, 'a line of text').join('\n');

      final read = extractDocumentText('long.txt', _bytes(long), budget: 40);

      expect(read!.truncated, isTrue);
      expect(read.text.length, lessThanOrEqualTo(40));
      // Cut on a line break: half a sentence reads as the file being corrupt.
      expect(read.text.endsWith('a line of text'), isTrue);
    });
  });
}
