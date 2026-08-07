import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../../projects/logic/project.dart';
import '../../projects/presentation/project_rail.dart';
import '../logic/bottom_panel.dart';
import '../logic/chat_rail.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/preview_panel.dart';
import 'bottom_panel.dart';
import 'chat_view.dart';
import 'preview_panel.dart';

/// The chat section: the open conversation, edge to edge — and, when that chat
/// belongs to a project, the project's cards in a rail beside it.
///
/// The history rail lives in the app sidebar, so the conversation is the whole
/// pane; a project chat adds the same Instructions/Context/Scheduled/Memory rail
/// as the Projects screen, so what steers the assistant is in reach while you
/// talk. Falls back to a nudge when no grid is selected, since a chat needs a
/// grid to answer.
class ChatPane extends ConsumerWidget {
  const ChatPane({super.key});

  /// The window width — the *whole* window, matching what a user reads as "the
  /// screen", not the pane inside the sidebar — at/above which the project rail
  /// sits beside the conversation.
  ///
  /// Below it the chat column would be too narrow for its composer (a fixed row
  /// of controls that can't shrink past ~550px, so it would overflow), so the
  /// rail steps aside by default and the top-bar toggle opens it as an overlay
  /// instead. At this width the column keeps ~615px — clear of the composer.
  static const _inlineWidth = 1240.0;

  static const _railWidth = 340.0;

  /// What the conversation keeps for itself before the preview panel is allowed
  /// to dock beside it.
  ///
  /// The composer is a fixed row of controls that can't shrink past ~550px, so
  /// this is that floor with room to breathe. Below it the panel floats over the
  /// chat instead — the same fallback, for the same reason, as the project rail.
  static const _chatMinWidth = 600.0;

  /// The preview panel takes a share of what's left rather than a fixed width:
  /// it is a work surface, so on a wide window it should be worth working in,
  /// and on a narrow one it shouldn't be the reason the chat is cramped.
  static const _previewMinWidth = 420.0;
  static const _previewMaxWidth = 760.0;

  /// The same deal vertically for the bottom panel, against a transcript that
  /// still has to be worth reading above it.
  ///
  /// The window can't go below 560 tall, so this always resolves — the bottom
  /// panel never needs the float-over-the-chat fallback the side panels have.
  static const _chatMinHeight = 260.0;
  static const _bottomMinHeight = 180.0;
  static const _bottomMaxHeight = 420.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);
    if (network == null) return const _NoGrid();

    // The project the open chat belongs to — a saved chat's own, or the one a
    // brand-new (not-yet-saved) chat is being composed in, so the rail shows
    // from the very first "New chat in this project", before any message. Select
    // it narrowly so this pane doesn't rebuild on every streamed token.
    final projectId = ref.watch(
      chatSessionsProvider.select((s) => s.openProjectId),
    );
    final project = ref.watch(projectByIdProvider(projectId));
    final override = ref.watch(chatRailOverrideProvider);
    final previewOpen = ref.watch(previewPanelOpenProvider);
    final bottomOpen = ref.watch(bottomPanelOpenProvider);

    // Measured on the whole window, not the pane inside the sidebar.
    final width = MediaQuery.sizeOf(context).width;
    final fits = width >= _inlineWidth;
    final open = project != null && (override ?? fits);
    // The top bar can't see this pane's width, so publish the resolved
    // visibility for its toggle to mirror. Post-frame: writing a provider during
    // build would throw.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        ref.read(chatRailVisibleProvider.notifier).set(open);
      }
    });
    // It sits beside the chat only when the column still clears its composer;
    // otherwise — only ever when the user forced it open on a narrow window — it
    // floats over the chat, dismissed by the scrim or the toggle.
    final inline = open && fits;
    final overlay = open && !fits;

    // Measured on this pane rather than on the window, unlike the rail above:
    // what decides the preview panel is the space actually left over, and the
    // rail may already be holding 340 of it.
    return LayoutBuilder(
      builder: (context, constraints) {
        final free = constraints.maxWidth - (inline ? _railWidth + 1 : 0);
        final previewWidth = (free * 0.45)
            .clamp(_previewMinWidth, _previewMaxWidth)
            .toDouble();
        // Whether the window can host the panel *beside* the chat at all. Kept
        // separate from `previewOpen` so the docked slot and the floating one
        // are never both in the tree.
        final previewFits = free - previewWidth >= _chatMinWidth;

        // A share of the height, but never more than leaves the transcript
        // above it worth reading. `room` is floored at zero before it becomes a
        // clamp bound — `clamp` asserts low <= high, so a pane laid out shorter
        // than the floor would throw rather than degrade.
        final room = (constraints.maxHeight - _chatMinHeight).clamp(
          0.0,
          double.infinity,
        );
        final bottomHeight = (constraints.maxHeight * 0.34)
            .clamp(_bottomMinHeight, _bottomMaxHeight)
            .clamp(0.0, room)
            .toDouble();

        // ChatView always sits in the same slot — Positioned.fill in a Stack,
        // first child of the Row — so toggling any panel, overlaying one,
        // switching to a plain chat, or resizing never rebuilds ChatView and
        // drops its scroll or a half-typed draft.
        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: ChatView(network: network)),
                  if (overlay) ...[
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: () => ref
                            .read(chatRailOverrideProvider.notifier)
                            .set(false),
                        child: const ColoredBox(color: Color(0x33000000)),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      bottom: 0,
                      width: _railWidth,
                      child: _RailPanel(project: project),
                    ),
                  ],
                  if (!previewFits)
                    Positioned.fill(
                      child: _PreviewOverlay(
                        open: previewOpen,
                        width: previewWidth,
                      ),
                    ),
                ],
              ),
            ),
            if (inline) ...[
              const VerticalDivider(width: 1),
              SizedBox(
                width: _railWidth,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ProjectRail(project: project),
                ),
              ),
            ],
            if (previewFits)
              _PreviewSlot(open: previewOpen, width: previewWidth),
          ],
        );

        // The bottom panel spans the whole pane, under the preview panel as
        // well as the chat — a terminal squeezed into the chat column alone
        // would be too narrow to read a wrapped command in.
        return Column(
          children: [
            Expanded(child: row),
            _BottomSlot(open: bottomOpen, height: bottomHeight),
          ],
        );
      },
    );
  }
}

/// The preview panel docked beside the conversation — the layout opening rather
/// than a panel appearing in it.
///
/// The panel is laid out at its full width the whole way through and the slot
/// widens under it, with the panel pinned to the slot's *leading* edge: as that
/// edge travels left the panel travels with it, entering from the window's
/// right. Pinning it to the trailing edge instead would hold it still and wipe
/// it into view, and animating the panel's own width would squash its rows flat
/// and stretch them back out.
///
/// The chat column only ever shrinks *to* its final width, never through
/// something narrower, so its composer can't overflow mid-animation.
class _PreviewSlot extends StatelessWidget {
  const _PreviewSlot({required this.open, required this.width});

  final bool open;
  final double width;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedContainer(
        duration: AppMotion.swap,
        curve: AppMotion.curve,
        width: open ? width : 0,
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: width,
          maxWidth: width,
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VerticalDivider(width: 1),
              Expanded(child: PreviewPanel()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bottom panel's slot, doing vertically what [_PreviewSlot] does
/// horizontally: the panel is laid out at full height throughout and pinned to
/// the slot's top edge, so as that edge rises the panel rises with it, sliding
/// up from under the window.
class _BottomSlot extends StatelessWidget {
  const _BottomSlot({required this.open, required this.height});

  final bool open;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedContainer(
        duration: AppMotion.swap,
        curve: AppMotion.curve,
        height: open ? height : 0,
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: height,
          maxHeight: height,
          child: const Column(
            children: [
              Divider(height: 1),
              Expanded(child: BottomPanel()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The preview panel floated over the conversation, on a window too narrow to
/// dock it — the fallback the project rail already takes, for the same reason.
///
/// Stays mounted while closed so it can slide both ways; [IgnorePointer] keeps
/// the invisible panel from swallowing clicks meant for the chat behind it.
class _PreviewOverlay extends ConsumerWidget {
  const _PreviewOverlay({required this.open, required this.width});

  final bool open;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IgnorePointer(
      ignoring: !open,
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedOpacity(
              duration: AppMotion.swap,
              curve: AppMotion.curve,
              opacity: open ? 1 : 0,
              child: GestureDetector(
                onTap: () =>
                    ref.read(previewPanelOpenProvider.notifier).close(),
                child: const ColoredBox(color: Color(0x33000000)),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: width,
            child: AnimatedSlide(
              duration: AppMotion.swap,
              curve: AppMotion.curve,
              offset: open ? Offset.zero : const Offset(1, 0),
              child: const _SlideOverSurface(
                child: PreviewPanel(onRaisedSurface: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The surface a panel floated over the conversation sits on — its own edge and
/// lift, so it reads as a layer above the chat rather than part of it.
class _SlideOverSurface extends StatelessWidget {
  const _SlideOverSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        // A layer above the page takes the raised fill, not the window's own:
        // in dark they would be the same colour and the panel would have no
        // edge at all.
        color: AppGlass.surfaceFill,
        border: Border(left: BorderSide(color: AppPalette.divider)),
        boxShadow: AppSurface.composerShadow,
      ),
      child: child,
    );
  }
}

/// The rail floated over the conversation on a window too narrow to sit it
/// alongside — a raised surface with its own edge and lift so it reads as a layer
/// above the chat, not part of it.
class _RailPanel extends StatelessWidget {
  const _RailPanel({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        border: Border(left: BorderSide(color: AppPalette.divider)),
        boxShadow: AppSurface.composerShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ProjectRail(project: project),
      ),
    );
  }
}

class _NoGrid extends ConsumerWidget {
  const _NoGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Follow the theme so this re-colours the instant the user flips Light/Dark.
    AppTheme.watch(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.messagesSquare,
            size: 40,
            color: AppPalette.textFaint,
          ),
          const SizedBox(height: 12),
          Text(
            'Pick a grid to chat with.',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.grids),
            child: const Text('Open grids'),
          ),
        ],
      ),
    );
  }
}
