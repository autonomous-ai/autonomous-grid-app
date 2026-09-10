import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/logic/chat_scope.dart';
import '../../features/chat/logic/chat_sessions_controller.dart';
import '../../features/code/logic/code_projects_controller.dart';
import 'panel_tabs.dart';

/// The scope a chat outside every project remembers its panels under.
///
/// Not an id a project can have — those are timestamps — so the workspace can
/// never end up sharing a panel with one of them.
const String kWorkspacePanelScope = '_workspace';

/// Whose tabs a panel is showing right now — the key they are remembered
/// under — or null while that isn't known.
///
/// Beside a chat and under it, it is the chat's project, or the workspace for
/// a chat in none: the same folder its Files tab browses and its terminals
/// start in (`activeChatWorkdirProvider`), so a panel and the folder under it
/// can't describe two different places. The two share the scope, so moving to
/// another project changes both at once. A chat that outlived its project
/// counts as the workspace's for the same reason — that is where its files
/// are. Null while the history is being read: the chat the app reopens on
/// isn't chosen yet, and the workspace's tabs opened for that moment would be
/// tabs nobody asked for.
///
/// Beside a Code project it is that project. Null while none is open, which
/// changes nothing — there is no panel on screen to change.
///
/// Naming features from `shared/` is the exemption `link_open.dart` takes, for
/// the same reason: a table mapping panels onto the screens holding them has
/// to name both sides.
final panelScopeProvider = Provider.family<String?, PanelHost>(
  (ref, host) => switch (host) {
    PanelHost.preview || PanelHost.bottom => _chatScope(ref),
    PanelHost.code => ref.watch(selectedCodeProjectProvider),
  },
);

String? _chatScope(Ref ref) {
  if (ref.watch(chatSessionsProvider.select((s) => s.loading))) return null;
  return ref.watch(openChatProjectProvider)?.id ?? kWorkspacePanelScope;
}
