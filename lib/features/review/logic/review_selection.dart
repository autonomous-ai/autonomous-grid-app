import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which file the Review surface has open, per folder — null for the list.
///
/// Per folder so switching project and coming back lands where you left off,
/// and so two folders can't fight over one selection. Not persisted: which line
/// you were reading is not worth carrying across a restart.
final reviewSelectionProvider =
    NotifierProvider.family<ReviewSelection, String?, String>(
      ReviewSelection.new,
    );

class ReviewSelection extends Notifier<String?> {
  ReviewSelection(this.folder);

  /// The folder this selection belongs to — the family argument.
  final String folder;

  @override
  String? build() => null;

  /// Open [path]'s diff.
  void open(String path) => state = path;

  /// Back to the file list.
  void close() => state = null;
}
