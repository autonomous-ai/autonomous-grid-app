import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../../features/agents/logic/agent_run_status.dart';

export '../../features/agents/logic/agent_run_status.dart' show AgentRunState;

/// The 8px status dot Claude's panel uses for a session, in its five states.
///
/// [elsewhere] reproduces the extension's hollow ring — a 2px outline over no
/// fill, for work running in another window: an agent that is busy, but not
/// busy *here*.
///
/// Static, not pulsing, on purpose: the dot is the extension's *state* mark and
/// stays put while the turn runs. The motion that says something is live lives
/// in [AgentRunLabel] and [PendingGlyph], which ride beside it.
class AgentRunStatus extends StatelessWidget {
  const AgentRunStatus({
    super.key,
    required this.state,
    this.size = 8,
    this.elsewhere = false,
  });

  final AgentRunState state;

  /// Diameter of the dot, sized against the 12–13pt text it sits beside.
  final double size;

  /// Draw only a ring in [state]'s colour — the extension's "running elsewhere".
  final bool elsewhere;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final color = switch (state) {
      AgentRunState.running => AppPalette.statusRunning,
      AgentRunState.waiting => AppPalette.statusWaiting,
      AgentRunState.idle => AppPalette.offline,
      AgentRunState.unread => AppPalette.statusUnread,
      AgentRunState.failed => AppPalette.statusFailed,
    };
    if (elsewhere) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.transparent,
          border: Border.all(color: color, width: 2),
        ),
      );
    }
    // Idle is the extension's dimmed dot — its opacity drops to 40% rather than
    // the colour itself muting, so the hue stays readable next to a busy dot.
    final alpha = state == AgentRunState.idle ? 0.4 : 1.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: alpha),
      ),
    );
  }
}

/// A child that breathes — opacity rides 1 → [low] → 1 on [period], the shape
/// of Claude's `focusFoldPulse` (a running row's label, 1.6s) and its
/// `pendingGlyph` marker (1.2s). Used by [AgentRunLabel] and [PendingGlyph];
/// both are the same motion at a different cadence.
class AgentPulse extends StatefulWidget {
  const AgentPulse({
    super.key,
    required this.child,
    this.period = const Duration(milliseconds: 1600),
    this.low = 0.55,
  });

  final Widget child;

  /// One full breathe cycle; the controller also reverses, so this is both
  /// halves of the wave.
  final Duration period;

  /// The floor of the opacity wave — how far the child dims at the bottom.
  final double low;

  @override
  State<AgentPulse> createState() => _AgentPulseState();
}

class _AgentPulseState extends State<AgentPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  @override
  void didUpdateWidget(AgentPulse old) {
    super.didUpdateWidget(old);
    if (old.period != widget.period) _controller.duration = widget.period;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honor Reduce Motion — a stopped pulse at 0 reads as the resting child,
    // so the turn still shows its live label without a constant flicker.
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduce Motion: a motionless pulse is just flicker at a busy edge of a
    // streamed turn, so stop breathing and hand back the resting child.
    if (MediaQuery.of(context).disableAnimations) return widget.child;
    // Its own layer, and cheaply so — see the note in `status_dot.dart`: a
    // pulse drawn in the shell's single layer would dirty the sidebar and the
    // pane sixty times a second for the whole length of a turn.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Opacity(
          opacity: 1 - (1 - widget.low) * _controller.value,
          child: widget.child,
        ),
      ),
    );
  }
}

/// The pulsing label beside a running agent — Claude's `runningLabel`, which
/// breathes while the agent works.
class AgentRunLabel extends StatelessWidget {
  const AgentRunLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return AgentPulse(
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: AppFont.medium,
          color: color ?? AppPalette.textSecondary,
        ),
      ),
    );
  }
}

/// Claude's `pendingGlyph`: a monospace ellipsis that pulses while the agent
/// composes its next step — the "still loading" beat between tool calls.
class PendingGlyph extends StatelessWidget {
  const PendingGlyph({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? AppPalette.textFaint;
    // The marker is a string the user never copies, but it *is* a token-adjacent
    // glyph (a step's "…"), so mono keeps it from wobbling between line heights.
    return AgentPulse(
      period: const Duration(milliseconds: 1200),
      low: 0.4,
      child: Text(
        '…',
        style: TextStyle(
          fontFamily: AppFont.mono,
          fontSize: 13,
          height: 1,
          color: ink,
        ),
      ),
    );
  }
}
