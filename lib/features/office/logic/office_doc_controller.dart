import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import 'docx/docx_parse.dart';
import 'docx_edit.dart';
import 'office_doc_state.dart';

/// The file types Docs offers in its picker.
///
/// One entry, and the screen says so: `.docx` is the format this app can open
/// *and* write back without turning a document into plain text. Offering `.doc`
/// here would promise a conversion nothing in the app performs.
const kDocsExtensions = ['docx'];

/// The document open in Docs, and the only way to open, edit, or save one.
///
/// Session state: closing the app closes the document. The file on disk is the
/// record — the app deliberately keeps no second copy of somebody's Word
/// document in `~/.grid`.
final officeDocProvider = NotifierProvider<OfficeDocController, OfficeDocState>(
  OfficeDocController.new,
);

class OfficeDocController extends Notifier<OfficeDocState> {
  /// The file exactly as it was opened — the baseline every save patches, so
  /// only the paragraphs the user changed are rewritten. Null when no document
  /// is open.
  DocxFile? _baseline;

  /// How many documents this session has opened — see [OfficeDocOpen.openId].
  int _opens = 0;

  @override
  OfficeDocState build() => const OfficeDocEmpty();

  /// Ask for a document and open it. Does nothing when the user cancels.
  Future<void> pickAndOpen() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Word documents', extensions: kDocsExtensions),
      ],
    );
    if (file == null) return;
    await open(file.path);
  }

  /// Open the document at [path], replacing whatever is on screen.
  ///
  /// Unsaved edits in the current document are the caller's problem to ask about
  /// first — this controller does not second-guess a deliberate open.
  Future<void> open(String path) async {
    state = OfficeDocOpening(path);
    final read = await _readFile(path);
    switch (read) {
      case _ReadFailed(:final message, :final error):
        _baseline = null;
        ref
            .read(appLogProvider)
            .failure('office', 'open failed: $path', error: error);
        state = OfficeDocFailed(message, path: path);
      case _ReadOk(:final bytes):
        final docx = DocxFile.open(bytes);
        if (docx == null) {
          _baseline = null;
          ref
              .read(appLogProvider)
              .warn(
                'office',
                'not an editable .docx: $path (${bytes.length} bytes)',
              );
          state = OfficeDocFailed(
            'Documents saved as .docx open here. An older .doc has to be '
            'saved as .docx in Word first — and a file that arrived '
            'incomplete will not open either.',
            path: path,
          );
          return;
        }
        _baseline = docx;
        state = OfficeDocOpen(
          openId: ++_opens,
          path: path,
          text: docx.text,
          savedText: docx.text,
          // The formatted read of the same bytes. Its own failure is not this
          // document's failure: a file whose styles or theme can't be read still
          // opens, and the Formatted view says what is missing.
          layout: parseDocxLayout(bytes),
        );
    }
  }

  /// What the user has typed. Cheap on purpose — it runs on every keystroke, so
  /// it only swaps the string and lets [OfficeDocOpen.dirty] derive the rest.
  void edit(String text) {
    final open = state;
    if (open is! OfficeDocOpen) return;
    if (open.text == text) return;
    // Clears a previous failure: the message named the save that failed, and
    // this is no longer that text.
    state = open.copyWith(text: text, save: const OfficeSaveIdle());
  }

  /// Write the edits back into the file they came from.
  Future<void> save() async {
    final open = state;
    final baseline = _baseline;
    if (open is! OfficeDocOpen || baseline == null) return;
    if (open.save is OfficeSaveRunning) return;

    final text = open.text;
    state = open.copyWith(save: const OfficeSaveRunning());
    try {
      await _writeAtomically(open.path, baseline.save(text));
    } on Object catch (error, stack) {
      ref
          .read(appLogProvider)
          .failure(
            'office',
            'save failed: ${open.path}',
            error: error,
            stackTrace: stack,
          );
      _fail(
        "Couldn't save to ${open.name}. Your edits are still here — check "
        'the file is not open in Word, then try again.',
      );
      return;
    }
    final latest = state;
    if (latest is! OfficeDocOpen || latest.path != open.path) return;
    // [savedText] is what was written, not what the editor holds now: the user
    // may have typed on while the write ran, and those keystrokes are still
    // unsaved.
    state = latest.copyWith(savedText: text, save: const OfficeSaveIdle());
  }

  void _fail(String message) {
    final open = state;
    if (open is! OfficeDocOpen) return;
    state = open.copyWith(save: OfficeSaveFailed(message));
  }

  Future<_FileRead> _readFile(String path) async {
    try {
      return _ReadOk(await File(path).readAsBytes());
    } on FileSystemException catch (error) {
      return _ReadFailed(
        "The file isn't there any more, or this computer has no permission "
        'to read it.',
        error,
      );
    }
  }

  /// Writes [bytes] to [path] via a neighbouring temp file.
  ///
  /// The rename is what makes this safe: a crash or a full disk mid-write leaves
  /// the *original* document intact rather than half a zip, which for a Word
  /// file means the difference between "not saved" and "not openable". The temp
  /// file sits in the same folder on purpose — a rename is only atomic within
  /// one filesystem.
  Future<void> _writeAtomically(String path, List<int> bytes) async {
    final temp = File('$path.grid-save');
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await temp.rename(path);
    } on FileSystemException {
      // Windows refuses a rename onto an existing file. Second-best there:
      // remove the original first, which is why the temp file is written and
      // flushed before anything touches it.
      await File(path).delete();
      await temp.rename(path);
    }
  }
}

/// The read either produced bytes or a sentence for the user — and the failure
/// carries the raw error too, because the log needs what the user must not read
/// (§6).
sealed class _FileRead {
  const _FileRead();
}

final class _ReadOk extends _FileRead {
  const _ReadOk(this.bytes);

  final Uint8List bytes;
}

final class _ReadFailed extends _FileRead {
  const _ReadFailed(this.message, this.error);

  final String message;
  final Object error;
}
