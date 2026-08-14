import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// Remembers that the one-time welcome screen has been shown, as
/// `~/.grid/app/welcome.json`.
///
/// App-owned (the CLI never touches it) and lenient like the other app stores: a
/// missing, corrupt, or hand-edited file reads as "not shown yet" rather than
/// throwing. Erring that way costs a returning user one extra screen; erring the
/// other way would hide it from the person it was written for. The file is
/// overridable so tests never read or write a real grid home.
class WelcomeStore {
  WelcomeStore({File? file}) : _file = file ?? GridPaths.welcomeFile;

  final File _file;

  bool load() {
    try {
      if (!_file.existsSync()) return false;
      final decoded = jsonDecode(_file.readAsStringSync());
      return decoded is Map && decoded['seen'] == true;
    } on Object {
      return false;
    }
  }

  /// Record that the screen has been shown, creating `app/` on first use.
  void save() {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({'seen': true}),
      flush: true,
    );
  }
}

/// The store, overridden in tests with a temp-file-backed instance.
final welcomeStoreProvider = Provider<WelcomeStore>((ref) => WelcomeStore());
