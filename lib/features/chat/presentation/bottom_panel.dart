import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/bottom_panel.dart';
import '../logic/panel_tabs.dart';
import 'panel_feature_view.dart';
import 'panel_tab_strip.dart';

/// The strip under the conversation: the same panel as the one beside the chat,
/// on the other edge.
///
/// Same tab strip, same "+" menu, same surfaces — a second panel that behaved
/// differently from the first would be a second thing to learn. What differs is
/// the shape it gives its contents: full pane width, so a terminal here can hold
/// a wrapped command that would be unreadable in the column beside the chat.
///
/// Opens straight into a terminal. The button that reveals this panel carries a
/// terminal glyph and nothing else, so making the user pick "Terminal" out of a
/// menu after pressing it is answering a question they already answered — while
/// the "+" is still there for a second one, or for anything else.
class BottomPanel extends ConsumerStatefulWidget {
  const BottomPanel({super.key});

  @override
  ConsumerState<BottomPanel> createState() => _BottomPanelState();
}

class _BottomPanelState extends ConsumerState<BottomPanel> {
  @override
  void initState() {
    super.initState();
    // The panel can already be open the first time this mounts — the user
    // switched away from Chat and back with it left open.
    _openTerminalIfEmpty(ref.read(bottomPanelOpenProvider));
  }

  /// Post-frame, never straight from `build`: writing a provider while the tree
  /// is building throws, and both callers are reacting to something that
  /// happened during a build.
  void _openTerminalIfEmpty(bool open) {
    if (!open) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tabs = ref.read(panelTabsProvider(PanelHost.bottom));
      if (tabs.tabs.isNotEmpty) return;
      ref
          .read(panelTabsProvider(PanelHost.bottom).notifier)
          .open(PanelFeature.terminal);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Opening the panel is what starts a shell — not this widget existing. The
    // slot keeps the panel mounted while closed so it can slide both ways, so
    // mounting can't be the trigger: every chat would quietly spawn one.
    ref.listen(
      bottomPanelOpenProvider,
      (_, open) => _openTerminalIfEmpty(open),
    );

    final state = ref.watch(panelTabsProvider(PanelHost.bottom));
    final active = state.active;
    final open = ref.watch(bottomPanelOpenProvider);

    // Nothing inside a closed panel may hold the keyboard, or a message typed
    // into the chat would go to a terminal nobody can see.
    return ExcludeFocus(
      excluding: !open,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelTabStrip(host: PanelHost.bottom),
          const Divider(height: 1),
          // Empty only for the frame between opening the panel and its first
          // tab arriving. A launcher here would flash a menu at somebody who
          // pressed a button that means one thing.
          Expanded(
            child: active == null
                ? const SizedBox.shrink()
                : panelFeatureView(
                    active,
                    host: PanelHost.bottom,
                    onClose: () => ref
                        .read(panelTabsProvider(PanelHost.bottom).notifier)
                        .close(active.id),
                  ),
          ),
        ],
      ),
    );
  }
}
