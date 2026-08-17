import '../../../core/folder_name.dart';
import 'docx/docx_model.dart';

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
    required this.text,
    required this.savedText,
    this.layout,
    this.save = const OfficeSaveIdle(),
  });

  /// The document with its formatting — what the Formatted view draws.
  ///
  /// Null when the file's own parts couldn't be read for display even though its
  /// text could. The two readers are independent on purpose, so a document with,
  /// say, a corrupt `styles.xml` still opens as text instead of not opening.
  final ParsedDocx? layout;

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

  /// What the editor holds.
  final String text;

  /// What is on disk — the yardstick for [dirty] rather than a flag somebody has
  /// to remember to clear.
  final String savedText;

  /// How the last save went, so the bar can say so where the user is looking.
  final OfficeSaveState save;

  bool get dirty => text != savedText;

  String get name => folderName(path);

  OfficeDocOpen copyWith({
    String? text,
    String? savedText,
    OfficeSaveState? save,
  }) => OfficeDocOpen(
    openId: openId,
    path: path,
    text: text ?? this.text,
    savedText: savedText ?? this.savedText,
    layout: layout,
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
