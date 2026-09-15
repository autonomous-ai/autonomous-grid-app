/// Starting a project from a phone.
///
/// The desktop's own flow adopts a folder somebody picked in Finder. A phone
/// cannot do that — it has no view of another machine's disk, and handing it
/// one would mean letting a pocket device name any path on this computer.
///
/// So the phone names the project and **this side decides where it goes**:
/// always [kPhoneProjectsRoot], never a path that came over the wire. The name
/// is still untrusted — it becomes a folder name — so it is sanitised the same
/// way an uploaded filename is.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../projects/logic/project.dart';

/// Where a project started from a phone is created.
///
/// The home folder rather than under `~/.grid`: somebody who starts a project
/// on the bus opens it in Finder when they get to the computer, and a folder
/// inside a dotted directory is one they will not find.
String get kPhoneProjectsRoot => '${GridPaths.userHome}/Grid';

/// The longest a project name may be.
///
/// Well under any filesystem's limit, and short enough to stay readable in a
/// sidebar that was not built for essays.
const int kProjectNameMax = 60;

/// Creates a project called [name] and returns its id.
///
/// Returns the id, or null with a sentence in [problem] — the record rather
/// than an exception, for the reason `startPhoneTurn` returns a string: every
/// refusal here is something the person can act on.
///
/// A name that is already a folder here is **adopted**, not refused: that is
/// what the desktop's `create` does with a folder it already knows, and a
/// second project over the same folder is the one outcome nobody wants.
({String? id, String? problem}) createPhoneProject(Ref ref, String name) {
  final safe = safeProjectName(name);
  if (safe == null) {
    return (
      id: null,
      problem: 'Give the project a name — letters, numbers, spaces or dashes.',
    );
  }
  final folder = Directory('$kPhoneProjectsRoot/$safe');
  try {
    folder.createSync(recursive: true);
  } on FileSystemException {
    return (id: null, problem: "Your computer couldn't make that folder.");
  }
  final project = ref
      .read(projectsProvider.notifier)
      .create(path: folder.path, name: safe);
  return (id: project.id, problem: null);
}

/// [name] as a folder name, or null when nothing usable is left.
///
/// Public because it is the one rule in this file worth stating and testing on
/// its own: everything else here is a folder being made and a record written.
///
/// Keeps letters, numbers, spaces, dashes and underscores and drops the rest.
/// That is deliberately narrow: this string becomes a path segment, and the
/// characters being thrown away — separators, dots, tildes — are exactly the
/// ones that would make it more than a segment. `..` needs no case of its own
/// because both its characters are gone by then, leaving nothing.
String? safeProjectName(String name) {
  final trimmed = name
      .trim()
      .replaceAll(RegExp(r'[^\w \-]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (trimmed.isEmpty || trimmed.length > kProjectNameMax) return null;
  return trimmed;
}
