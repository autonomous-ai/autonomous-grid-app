import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'branch_ref.dart';
import 'review_controller.dart';
import 'review_scope.dart';

/// The branches a repository can be compared against, remote ones first.
///
/// Keyed by the repository root rather than the project folder: two projects
/// inside the same repository see the same branches, and asking Git twice for
/// the same list would be work for nothing.
///
/// Empty when Git can't answer — the picker then offers only the comparison
/// that needs no branch at all, which is the one it starts on.
final reviewBaseRefsProvider = FutureProvider.family<List<BranchRef>, String>(
  (ref, root) => ref.read(reviewLoaderProvider).baseRefs(root),
);

/// The recent commits the scope menu can open, newest first.
///
/// Keyed by repository root for the same reason as the branches, and read when
/// the menu opens rather than with every snapshot: a commit list is only worth
/// fetching for someone who is about to pick from it.
final reviewCommitsProvider = FutureProvider.family<List<CommitRef>, String>(
  (ref, root) => ref.read(reviewLoaderProvider).recentCommits(root),
);
