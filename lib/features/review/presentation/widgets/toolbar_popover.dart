import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/panel_visibility.dart';
import '../../../../shared/widgets/popover_surface.dart';

/// A panel hung under a control in the toolbar.
///
/// Its own overlay rather than a `MenuAnchor`: these panels hold text fields,
/// and a menu takes the arrow keys and Escape for its own navigation — which is
/// most of what typing in one needs.
///
/// Owns the four things every one of them has to get right: where the panel
/// hangs, that a click outside dismisses it while a click inside doesn't, that
/// it closes when the tab it belongs to stops being the one on screen (the
/// overlay floats above *every* tab), and the surface it is drawn on.
class ToolbarPopover extends StatefulWidget {
  const ToolbarPopover({
    super.key,
    required this.width,
    required this.trigger,
    required this.panel,
    this.dismissible = true,
  });

  final double width;

  /// The control that opens it, told whether it is open and how to toggle it.
  final Widget Function(BuildContext context, bool open, VoidCallback toggle)
  trigger;

  /// What is in the panel, given the way to close itself.
  final Widget Function(BuildContext context, VoidCallback close) panel;

  /// False while something the panel is the only report of is in flight — a
  /// stray click behind it would otherwise take the outcome away mid-run.
  final bool dismissible;

  @override
  State<ToolbarPopover> createState() => _ToolbarPopoverState();
}

class _ToolbarPopoverState extends State<ToolbarPopover> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();

  /// Ties the control and its panel into one region, so a click on either is
  /// "inside" and only a click elsewhere dismisses.
  final _group = Object();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final open = _portal.isShowing;
    // The panel is mounted in the app's overlay, above every tab — so switching
    // to another one would leave it floating over a surface it has nothing to
    // do with. After the frame, never during it: closing sets state.
    if (open && !PanelTabVisible.of(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _portal.isShowing) close();
      });
    }

    return TapRegion(
      groupId: _group,
      onTapOutside: (_) {
        if (open && widget.dismissible) close();
      },
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => Positioned(
            width: widget.width,
            // Right-aligned because the control is: a panel opening leftwards
            // from a button at the end of the toolbar would run off the panel's
            // own edge.
            child: CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 6),
              child: TapRegion(
                groupId: _group,
                child: PopoverSurface(child: widget.panel(context, close)),
              ),
            ),
          ),
          child: widget.trigger(context, open, toggle),
        ),
      ),
    );
  }

  void toggle() =>
      setState(() => _portal.isShowing ? _portal.hide() : _portal.show());

  void close() => setState(_portal.hide);
}
