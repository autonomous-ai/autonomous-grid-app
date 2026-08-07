import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'review_controller.dart';
import 'unified_diff.dart';

/// Which file's diff to fetch: the folder being reviewed, and the file's path
/// inside its repository.
typedef ReviewPatchKey = ({String folder, String path});

/// Above this many characters the diff is parsed off the UI isolate.
///
/// Not every diff — spinning up an isolate costs a few milliseconds, which is
/// more than parsing an ordinary change takes. This is the size at which the
/// parse itself would start to be felt as a dropped frame.
const int kInlineParseLimit = 200 * 1024;

/// One file's diff, fetched when the user opens it and not before.
///
/// The whole reason a branch with sixteen thousand changed lines opens
/// instantly: the file *list* is one `git status`, and each file's contents are
/// only read when someone looks at them.
///
/// Watches [reviewProvider] rather than taking the file as part of the key, so
/// a file that changes under the app — an agent editing while the panel is open,
/// a staging click — re-reads instead of showing a diff that has moved on.
/// Null when Git couldn't produce it; the pane says so rather than drawing an
/// empty file.
final reviewPatchProvider =
    FutureProvider.family<DiffFilePatch?, ReviewPatchKey>((ref, key) async {
      final state = await ref.watch(reviewProvider(key.folder).future);
      if (state is! ReviewReady) return null;

      final snapshot = state.snapshot;
      final file = snapshot.files
          .where((candidate) => candidate.path == key.path)
          .firstOrNull;
      if (file == null) return null;

      final raw = await ref
          .read(reviewActionsProvider)
          .patch(root: snapshot.root, scope: snapshot.scope, file: file);
      if (raw == null) return null;
      if (raw.length <= kInlineParseLimit) return parseUnifiedDiff(raw);
      return compute(parseUnifiedDiff, raw);
    });
