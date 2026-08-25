import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// Remembers the newest build the user has closed the update banner on, as
/// `~/.grid/app/update_dismissed.json`.
///
/// Per **build**, not a plain "hidden" flag: closing the banner is an answer
/// about *this* release, and a release after it deserves to be offered. A flag
/// would silence every future update on one click, which is the same silent
/// dead end Sparkle's own "Skip This Version" creates.
///
/// App-owned (the CLI never touches it) and lenient like the other app stores: a
/// missing, corrupt, or hand-edited file reads as "nothing dismissed" rather
/// than throwing. Erring that way costs a returning user one banner they have
/// already seen; erring the other way hides an update from them for good. The
/// file is overridable so tests never read or write a real grid home.
class UpdateDismissStore {
  UpdateDismissStore({File? file})
    : _file = file ?? GridPaths.updateDismissedFile;

  final File _file;

  /// The build the banner was last closed on, or null when it never was.
  int? load() {
    try {
      if (!_file.existsSync()) return null;
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return null;
      final build = decoded['build'];
      return build is int ? build : null;
    } on Object {
      return null;
    }
  }

  /// Record that the banner was closed on [build], creating `app/` on first use.
  ///
  /// Swallows a write failure on purpose: not remembering the dismissal shows
  /// the banner again later, which is a nuisance. Letting the error out of a
  /// close button would turn that nuisance into a crash.
  void save(int build) {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({'build': build}),
        flush: true,
      );
    } on Object {
      return;
    }
  }
}

/// The seam onto the dismissal file, overridden in tests with a temp dir.
final updateDismissStoreProvider = Provider<UpdateDismissStore>(
  (ref) => UpdateDismissStore(),
);
