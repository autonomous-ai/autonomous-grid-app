import 'package:flutter/foundation.dart';

/// A file on its way from one part of the app to another, under the pointer.
///
/// A type of its own rather than the bare path it carries. A
/// `DragTarget<String>` would light up for anything anybody in the app ever
/// decides to drag, and what a message will take is a decision worth naming out
/// loud rather than leaving to whichever strings happen to fly past.
@immutable
class FileDrag {
  const FileDrag(this.path);

  /// Where the file is on disk, absolute — the same form "Add to chat" hands
  /// over, so both gestures end in the same place.
  final String path;
}
