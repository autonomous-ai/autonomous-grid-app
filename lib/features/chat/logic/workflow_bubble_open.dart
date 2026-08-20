import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the workflow bubble — the top-bar entry point into the
/// orchestration overview — is showing.
///
/// Its own flag rather than a `PanelHost`: the bubble isn't a panel around the
/// conversation, it's a small always-on-top indicator, and per-conversation
/// hover/pin behaviour is separate again — this only controls whether the
/// feature's icon is visible at all. Not persisted, for the same reason the
/// preview panel isn't — see `previewPanelOpenProvider`.
final workflowBubbleOpenProvider =
    NotifierProvider<WorkflowBubbleOpenNotifier, bool>(
      WorkflowBubbleOpenNotifier.new,
    );

class WorkflowBubbleOpenNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}
