import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the workflow strip — `WorkflowFlowLine`, the orchestration overview
/// above the conversation — may be shown at all.
///
/// A gate over the strip's own per-chat rule, not a replacement for it: the
/// strip still draws nothing for a chat on the grid's ordinary pick, so this
/// only ever decides whether a chat that *does* have a routing group shows its
/// overview. That is the question the top bar's workflow button asks, which is
/// why it is the only thing that writes here.
///
/// **Starts open.** A routed chat's overview is the feature, not an opt-in: the
/// strip appears by itself the moment a chat is routed, and this exists so a
/// user who would rather read the transcript without it can put it away.
///
/// Not persisted, for the same reason the preview panel isn't — see
/// `previewPanelOpenProvider`.
final workflowBubbleOpenProvider =
    NotifierProvider<WorkflowBubbleOpenNotifier, bool>(
      WorkflowBubbleOpenNotifier.new,
    );

class WorkflowBubbleOpenNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
}
