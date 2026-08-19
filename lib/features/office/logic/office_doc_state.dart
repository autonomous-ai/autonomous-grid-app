import 'dart:typed_data';

import '../../../core/folder_name.dart';
import 'docx_format.dart';
import 'docx_paragraph_style.dart';

/// What the Docs screen is showing right now.
///
/// One document at a time, and every state it can be in is one of these — so the
/// screen and its bar can only draw a state that is actually reachable.
sealed class OfficeDocState {
  const OfficeDocState();
}

/// No document yet — the screen offers to open one.
final class OfficeDocEmpty extends OfficeDocState {
  const OfficeDocEmpty();
}

/// A file is being read off disk. Carries the path so the screen can name what
/// it is waiting for instead of showing a bare spinner.
final class OfficeDocOpening extends OfficeDocState {
  const OfficeDocOpening(this.path);

  final String path;

  String get name => folderName(path);
}

/// The document is open and editable.
final class OfficeDocOpen extends OfficeDocState {
  const OfficeDocOpen({
    required this.openId,
    required this.path,
    required this.lines,
    required this.savedLines,
    this.bytes,
    this.formats = const [],
    this.styles = const [],
    this.savedStyles = const [],
    this.caretLine = 0,
    this.pageWidthPx = 816,
    this.staleOnDisk = false,
    this.save = const OfficeSaveIdle(),
  });

  /// How each paragraph of the file as it was *opened* looks — what the Edit view
  /// styles its fields from, by line index.
  ///
  /// It doesn't grow when the user splits a paragraph: a new paragraph has no
  /// entry, and the view falls back to the format of the one it was split from,
  /// which is also the style the save gives it (`_insertLines` clones the
  /// paragraph above). One rule, in two places that have to agree.
  final List<DocxLineFormat> formats;

  /// What the toolbar has changed and Save has not yet written — one entry per
  /// line, null where the user has changed nothing.
  ///
  /// A delta rather than a replacement format, for the reason
  /// [DocxParagraphStyle] gives: what is written back has to be the properties
  /// the user pressed and not the whole resolved look, or a heading stops
  /// following its style the first time somebody centres it.
  ///
  /// Kept in step with [lines] by every edit that changes the line count, so
  /// index i of one is index i of the other — the same rule the save relies on.
  final List<DocxParagraphStyle?> styles;

  /// The formatting that is already in the file, the yardstick for [dirty] —
  /// the same job [savedLines] does for the words.
  final List<DocxParagraphStyle?> savedStyles;

  /// Which paragraph the caret was last in. What the toolbar and the ruler show
  /// the state of, and what they change.
  ///
  /// Held here rather than in the editor's own state because two widgets on
  /// opposite sides of the screen need the same answer, and because a toolbar
  /// button takes the focus off the page when it is pressed — the last
  /// paragraph the user was *in* has to outlive that.
  final int caretLine;

  /// How paragraph [index] looks right now — what is in the file, with anything
  /// the toolbar has changed laid over it.
  ///
  /// The one place the two are combined, so the page, the toolbar and the ruler
  /// cannot disagree about what a paragraph looks like. A line past the end of
  /// [formats] is one the user split off another and takes that one's look,
  /// which is also the look the save gives it (`_insertLines` clones the
  /// paragraph above).
  DocxLineFormat formatAt(int index) {
    if (formats.isEmpty) return DocxLineFormat.fallback;
    final at = index < formats.length ? index : formats.length - 1;
    return formats[at].withStyle(index < styles.length ? styles[index] : null);
  }

  /// The document's own page width in logical pixels — US Letter until the file
  /// says otherwise. Both views size their sheet by it.
  final double pageWidthPx;

  /// The file exactly as it was read — the yardstick for "has this changed under
  /// us".
  ///
  /// Kept as bytes rather than as a hash because it costs nothing to keep and
  /// answers exactly: [OfficeDocController] compares a fresh read against it to
  /// tell the assistant's edit from the app's own save, and refuses to write a
  /// patch built from a file that has moved on. Stays the *opened* bytes for the
  /// life of the document, which is what makes that comparison mean anything.
  final Uint8List? bytes;

  /// Which *opening* this is — bumped every time a document is opened, the same
  /// file included.
  ///
  /// The editor needs it to know when to take a new text: [path] alone can't
  /// answer, because re-opening the file you were just editing is how a person
  /// throws their edits away, and that leaves the path unchanged while the text
  /// has to go back to what is on disk.
  final int openId;

  /// The file this came from, and where [text] goes back to.
  final String path;

  /// What the editor holds: one entry per paragraph, in document order.
  ///
  /// A list rather than one string joined by newlines, because a paragraph can
  /// contain a newline of its own — Word's soft break (Shift+Enter), which whole
  /// sections of real documents are built out of. Joined, there would be no way
  /// to tell that break from the end of the paragraph, and a save would turn one
  /// paragraph into several.
  final List<String> lines;

  /// What is on disk — the yardstick for [dirty] rather than a flag somebody has
  /// to remember to clear.
  final List<String> savedLines;

  /// How the last save went, so the bar can say so where the user is looking.
  final OfficeSaveState save;

  /// The file on disk has moved on since it was opened — the assistant edited it —
  /// and the app has *not* re-read it, because there are unsaved edits here that a
  /// re-read would throw away.
  ///
  /// It matters more than a stale view: a save patches the bytes the document was
  /// opened with, so writing while this is true would undo whatever changed the
  /// file. The screen says so and offers the reload; [OfficeDocController.save]
  /// refuses rather than trusting the user read it.
  final bool staleOnDisk;

  bool get dirty {
    if (lines.length != savedLines.length) return true;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i] != savedLines[i]) return true;
    }
    // Formatting counts as an edit as much as typing does — a document that was
    // only centred still has something in it the file has not got, and a Save
    // button that stayed grey would lose it.
    //
    // Compared by identity, which is exact here rather than approximate: a
    // change always makes a new [DocxParagraphStyle], and a save records the
    // very list it wrote. Nothing in this feature builds an equal-but-separate
    // one, so there is no case where identity says "changed" and the file
    // disagrees.
    if (styles.length != savedStyles.length) return true;
    for (var i = 0; i < styles.length; i++) {
      if (!identical(styles[i], savedStyles[i])) return true;
    }
    return false;
  }

  String get name => folderName(path);

  OfficeDocOpen copyWith({
    List<String>? lines,
    List<String>? savedLines,
    List<DocxParagraphStyle?>? styles,
    List<DocxParagraphStyle?>? savedStyles,
    int? caretLine,
    OfficeSaveState? save,
    bool? staleOnDisk,
  }) => OfficeDocOpen(
    openId: openId,
    path: path,
    lines: lines ?? this.lines,
    savedLines: savedLines ?? this.savedLines,
    styles: styles ?? this.styles,
    savedStyles: savedStyles ?? this.savedStyles,
    caretLine: caretLine ?? this.caretLine,
    bytes: bytes,
    formats: formats,
    pageWidthPx: pageWidthPx,
    staleOnDisk: staleOnDisk ?? this.staleOnDisk,
    save: save ?? this.save,
  );
}

/// The file couldn't be opened, with the reason in the user's words and a path
/// to name what failed.
final class OfficeDocFailed extends OfficeDocState {
  const OfficeDocFailed(this.message, {required this.path});

  final String message;
  final String path;

  String get name => folderName(path);
}

/// Where a save got to.
///
/// Its own type rather than two flags on [OfficeDocOpen]: "saving" and "failed"
/// can't both be true, and a failure has to carry its reason.
sealed class OfficeSaveState {
  const OfficeSaveState();
}

/// Nothing in flight — the normal state, whether or not there are edits.
final class OfficeSaveIdle extends OfficeSaveState {
  const OfficeSaveIdle();
}

/// Writing to disk. Short, but it is a whole-file rewrite, so the bar disables
/// Save rather than letting two of them race.
final class OfficeSaveRunning extends OfficeSaveState {
  const OfficeSaveRunning();
}

/// The save failed and the edits are still only in the app — said plainly,
/// because the user is about to close a window believing their work is on disk.
final class OfficeSaveFailed extends OfficeSaveState {
  const OfficeSaveFailed(this.message);

  final String message;
}
