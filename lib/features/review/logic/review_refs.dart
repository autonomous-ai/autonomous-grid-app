import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'review_controller.dart';

/// The branches a repository can be compared against, remote ones first.
///
/// Keyed by the repository root rather than the project folder: two projects
/// inside the same repository see the same branches, and asking Git twice for
/// the same list would be work for nothing.
///
/// Empty when Git can't answer — the picker then offers only the comparison
/// that needs no branch at all, which is the one it starts on.
final reviewBaseRefsProvider = FutureProvider.family<List<String>, String>(
  (ref, root) => ref.read(reviewLoaderProvider).baseRefs(root),
);
