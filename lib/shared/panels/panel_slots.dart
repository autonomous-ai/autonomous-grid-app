import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import '../widgets/panel_splitter.dart';
import 'panel_tabs.dart';

/// The conversation, laid out at [width] however wide its slot happens to be.
///
/// The slot is flexible and gives way to the panel beside it, down to nothing
/// when that panel takes the pane. The work inside keeps [width] throughout and
/// is pinned to the slot's *trailing* edge, so as that edge travels left the
/// conversation travels with it and leaves past the window's left side — the
/// mirror of what [PanelDockSlot] does coming the other way.
///
/// Two things this buys, both of which were bugs waiting: a composer that is
/// never laid out below its own floor (a squeezed one stripes yellow and black
/// for the length of the animation), and a conversation that is *hidden* rather
/// than unbuilt, so the draft in the box and the answer still streaming in are
/// both there when it comes back.
class PanelMainSlot extends StatelessWidget {
  const PanelMainSlot({
    super.key,
    required this.width,
    required this.hidden,
    required this.child,
  });

  final double width;

  /// The panel has the pane and the conversation is off the left edge. It stays
  /// mounted so it can slide back with everything in it, which is exactly why it
  /// must not keep the keyboard: the same rule the panel obeys while closed,
  /// pointing the other way — a message typed at a full-screen terminal must not
  /// land in a composer nobody can see.
  final bool hidden;

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: OverflowBox(
      alignment: Alignment.centerRight,
      minWidth: width,
      maxWidth: width,
      child: ExcludeFocus(excluding: hidden, child: child),
    ),
  );
}

/// A panel docked beside the conversation — the layout opening rather than a
/// panel appearing in it.
///
/// The panel is laid out at its full width the whole way through and the slot
/// widens under it, with the panel pinned to the slot's *leading* edge: as that
/// edge travels left the panel travels with it, entering from the window's
/// right. Pinning it to the trailing edge instead would hold it still and wipe
/// it into view, and animating the panel's own width would squash its rows flat
/// and stretch them back out.
///
/// The conversation only ever shrinks *to* its final width, never through
/// something narrower, so its composer can't overflow mid-animation.
class PanelDockSlot extends StatelessWidget {
  const PanelDockSlot({
    super.key,
    required this.open,
    required this.width,
    required this.onResize,
    required this.onResetSize,
    required this.child,
  });

  final bool open;
  final double width;

  /// The seam dragged, in pixels. The panel is on the right, so a *negative*
  /// delta makes it wider — see the callers, which resize from the width just
  /// resolved rather than from the drag's start.
  final ValueChanged<double> onResize;

  final VoidCallback onResetSize;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedContainer(
      duration: AppMotion.swap,
      curve: AppMotion.curve,
      width: open ? width : 0,
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: width,
        maxWidth: width,
        // Fades with the slide. Closing the last tab empties the panel in the
        // same frame the slide begins, so without this the launcher flashes
        // up at full width and *then* leaves.
        child: AnimatedOpacity(
          duration: AppMotion.swap,
          curve: AppMotion.curve,
          opacity: open ? 1 : 0,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The seam doubles as the handle. It rides inside the slot so
              // it slides in with the panel rather than appearing under the
              // pointer a frame before the panel it belongs to.
              PanelSplitter(
                axis: Axis.vertical,
                onDrag: onResize,
                onReset: onResetSize,
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A panel floated over the conversation, on a pane too narrow to dock it — the
/// fallback both panels take rather than squeezing a composer past its floor.
///
/// Stays mounted while closed so it can slide both ways; [IgnorePointer] keeps
/// the invisible panel from swallowing clicks meant for the conversation behind
/// it. The scrim closes it, which is the only way out a floating panel has: the
/// toggle that opened it may be under the panel.
class PanelFloatSlot extends ConsumerWidget {
  const PanelFloatSlot({
    super.key,
    required this.host,
    required this.open,
    required this.width,
    required this.child,
  });

  /// Which panel this is, so the scrim closes the right one.
  final PanelHost host;

  final bool open;
  final double width;

  /// The panel itself. Pass it its raised-surface variant: it is a layer above
  /// the page here, not part of it.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IgnorePointer(
    ignoring: !open,
    child: Stack(
      children: [
        Positioned.fill(
          child: AnimatedOpacity(
            duration: AppMotion.swap,
            curve: AppMotion.curve,
            opacity: open ? 1 : 0,
            child: GestureDetector(
              onTap: () => ref.read(panelOpenProvider(host).notifier).close(),
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
            child: _SlideOverSurface(child: child),
          ),
        ),
      ],
    ),
  );
}

/// The surface a panel floated over the conversation sits on — its own edge and
/// lift, so it reads as a layer above the conversation rather than part of it.
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
