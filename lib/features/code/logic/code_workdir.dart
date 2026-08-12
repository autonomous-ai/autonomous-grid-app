import '../../../core/grid_paths.dart';
import 'code_argv.dart';

/// Where the app keeps this project's working checkout on disk —
/// `~/.grid/app/code/<project>`.
///
/// The one place that answer is computed, so the flow that refreshes the copy
/// after a task ships, the header button that opens it, and the side panel that
/// browses/reviews/runs a terminal in it all point at the same folder.
String projectClonePath({
  required String projectName,
  required String projectId,
}) => GridPaths.projectCodeDir(
  cloneFolderName(projectName: projectName, projectId: projectId),
).path;
