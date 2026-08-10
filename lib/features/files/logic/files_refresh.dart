import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/file_changes.dart';
import '../../../shared/workspace/workspace_entries.dart';
import 'file_preview.dart';
import 'files_path.dart';

/// Re-reads whatever the panel is showing the moment it changes on disk.
///
/// [filePreviewProvider] is `autoDispose`, which drops a file's contents once
/// nothing is looking at it — but a file *on screen* is being looked at, so its
/// read stays cached for exactly as long as the user is reading it. That is the
/// case that matters: the assistant rewrites these files while they are open,
/// and without this the viewer keeps showing the version from before the edit
/// with nothing to say it is stale.
///
/// Watched once by the panel rather than listened to per widget: the file tree
/// is hidden half the time and the viewer is rebuilt whenever the selection
/// moves, and a refresh that only arrives while somebody is watching for it is
/// the bug this exists to fix.
final filesAutoRefreshProvider = Provider<void>((ref) {
  ref.listen(fileChangesProvider, (_, notice) {
    for (final path in notice.paths) {
      ref.invalidate(filePreviewProvider(path));

      // The listing too: a file the assistant created is a row that isn't in
      // the tree yet, and one it deleted is a row pointing at nothing. Both
      // keys, because the tree asks for hidden files and the `@`-mention menu
      // asks for the same folder without them.
      final parent = parentFolderOf(path);
      if (parent == null) continue;
      ref.invalidate(workdirEntriesProvider((path: parent, hidden: true)));
      ref.invalidate(workdirEntriesProvider((path: parent, hidden: false)));
    }
  });
});
