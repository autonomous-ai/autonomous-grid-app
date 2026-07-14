import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/project.dart';

/// Ask the user for a folder and add it as a project.
///
/// The OS picker is the whole flow — no path to type, no way to pick something
/// that isn't there. Returns the project, or null when the user backed out.
Future<Project?> addProjectFromPicker(WidgetRef ref) async {
  final path = await getDirectoryPath(
    confirmButtonText: 'Add project',
  );
  if (path == null) return null;
  return ref.read(projectsProvider.notifier).add(path);
}
