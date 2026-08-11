import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// Where feedback goes when it can't be sent.
///
/// The user wrote something and pressed Send; a server that is down, missing the
/// route, or unreachable on a plane is not a reason to throw that away. Each
/// failed attempt is written verbatim — the same payload the request carried —
/// so a retry sends exactly what was meant, and a user who gives up can hand us
/// the file instead.
///
/// Not an automatic outbox: nothing here is re-sent in the background. Retrying
/// is the user's move, from the dialog that is still open in front of them.
class FeedbackOutbox {
  const FeedbackOutbox(this.directory);

  /// `~/.grid/feedback`, created on demand.
  final Directory directory;

  /// Writes [payload] and returns the file, or null if even that failed (a
  /// read-only home, a full disk). The caller says less in that case; it never
  /// throws, because this runs on the failure path of something else.
  File? save(Map<String, dynamic> payload, {required DateTime now}) {
    try {
      directory.createSync(recursive: true);
      final file = File('${directory.path}/${feedbackFileName(now)}');
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
      return file;
    } on Object {
      return null;
    }
  }
}

/// `feedback-20260811-143002.json` — sortable, and unique per second, which is
/// finer than a person can press Send twice.
String feedbackFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${now.year}${two(now.month)}${two(now.day)}';
  final time = '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return 'feedback-$date-$time.json';
}

/// The outbox, pointed at `~/.grid/feedback`.
final feedbackOutboxProvider = Provider<FeedbackOutbox>(
  (ref) => FeedbackOutbox(GridPaths.feedbackDir),
);
