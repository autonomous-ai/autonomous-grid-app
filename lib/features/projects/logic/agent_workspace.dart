import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/workspace/workspace_entries.dart';
import '../../agents/logic/agent_providers.dart';

/// What's in the assistant's own folder right now, folders first then files,
/// each group alphabetical — the order a file manager would show, so the screen
/// and Finder agree.
///
/// The folder is the assistant's, which is what keeps this here rather than in
/// `shared/`: everything about *reading* a folder lives in
/// [readWorkspaceEntries], and this is only the one folder that belongs to the
/// agent. Refresh with `ref.invalidate` after the user has been off adding
/// files.
final workspaceEntriesProvider = FutureProvider<List<WorkspaceEntry>>(
  (ref) => readWorkspaceEntries(ref.watch(agentWorkspaceDirProvider)),
);
