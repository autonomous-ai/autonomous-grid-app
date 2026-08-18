import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/folder_watch.dart';
import 'files_browser.dart';

/// Keeps a watcher on every folder one Files tab has open — the root it is
/// pinned to, plus each folder the user has expanded.
///
/// Watched by the panel rather than by the tree, because the tree is only in the
/// widget list while `showTree` is on: watchers that came and went with it would
/// leave the listing to go stale in exactly the moment nobody could see it
/// happening, and the tree would come back holding what it read before.
///
/// The value is void, so re-running this — which happens on every expand and
/// collapse — never rebuilds the panel that watches it. What it does is drop the
/// watcher on a folder just closed and open one on a folder just expanded.
final openFoldersWatchProvider = Provider.autoDispose
    .family<void, ({String tabId, String root})>((ref, key) {
      ref.watch(folderWatchProvider(key.root));
      final expanded = ref.watch(
        filesBrowserProvider(key.tabId).select((s) => s.expanded),
      );
      for (final path in expanded) {
        ref.watch(folderWatchProvider(path));
      }
    });
