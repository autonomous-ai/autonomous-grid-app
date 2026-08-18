part of 'chat_composer.dart';

class _Actions extends StatelessWidget {
  const _Actions({
    required this.canAttach,
    required this.sending,
    required this.canSend,
    required this.busySendTooltip,
    required this.approvalPicker,
    this.agentPicker,
    required this.modelPicker,
    required this.onAttachFile,
    required this.onOpenCommands,
    required this.messageController,
    required this.onSend,
    required this.onStop,
  });

  final bool canAttach;
  final bool sending;
  final bool canSend;

  /// What Send promises while a turn is still running — see
  /// [ComposerSection.busySendTooltip].
  final String busySendTooltip;

  /// What the assistant may do to this computer — null when nothing on this turn
  /// can touch it (a picture goes to the grid, which has no filesystem), so the
  /// control isn't offered where it would mean nothing.
  final Widget? approvalPicker;

  /// Which agent answers text-only turns — sits just left of the model it runs.
  /// It stays visible on a pictured turn even though that request bypasses it.
  final Widget? agentPicker;
  final Widget modelPicker;
  final VoidCallback onAttachFile;
  final VoidCallback onOpenCommands;

  /// Where a transcribed voice clip lands — see [_MicButton].
  final TextEditingController messageController;
  final VoidCallback onSend;

  /// Cuts the reply off where it is. The same button as Send, because the thing
  /// you reach for to stop something is the thing that started it.
  final VoidCallback onStop;

  /// The narrowest each group can be drawn, in logical pixels — and the flex
  /// weights that share the row in that proportion.
  ///
  /// Left: attach 32 + commands 32 + gap 4 + the access pill's own floor 58.
  /// Right: agent pill 58 + 8 + model pill 58 + 4 + mic 32 + 4 + stop 32 + 6 +
  /// send 32 — counting Stop, which only appears mid-turn and must not be the
  /// thing that breaks the row when it does.
  ///
  /// Re-measure these if a control is added to either side: they are the
  /// composer's real floor, and a stale one shows up as stripes rather than as a
  /// layout that merely looks tight.
  static const _leftFloor = 126;
  static const _rightFloor = 234;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      // Two groups pushed apart, rather than one flat row with a spacer in the
      // middle. The spacer version was the reason the composer had a hard floor
      // around 550px: every control was inflexible, so a narrower column
      // overflowed instead of tightening, and the chat pane had to refuse to go
      // below that. Grouped, each side is a [Flexible] that gives its pills room
      // to ellipsis — and the pane's floor becomes what this row can really do.
      //
      // Loose fit, so on a roomy composer both groups still take their natural
      // width and `spaceBetween` puts them exactly where they were.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // What goes into the turn.
          Flexible(
            // Weighted by what each side actually needs, not shared evenly.
            //
            // An even share is what the composer had, and it striped a 440px
            // column by 1.9px with every control showing: two loose Flexibles
            // split the row down the middle, so this group was handed 206px to
            // spend 126 of while the group opposite needed 234 and had the same
            // 206. Eighty pixels of slack sat unused *between* them.
            //
            // The weights are the two floors: 32 + 32 + 4 + 58 here, and
            // 58 + 8 + 58 + 4 + 32 + 4 + 32 + 6 + 32 there (a pill's own floor is
            // 58 — leading + gap + ellipsis + caret + padding). Weighting by them
            // means both sides reach their floor at the same width — 388px plus
            // this padding — instead of the wider side breaking first at nearly
            // 480. Nothing changes on a roomy composer: a loose fit still lets
            // each group take its natural size, and `spaceBetween` still puts
            // them where they were.
            flex: _leftFloor,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AttachButton(canAttach: canAttach, onAttach: onAttachFile),
                _CommandsButton(enabled: !sending, onPressed: onOpenCommands),
                if (approvalPicker != null) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 178),
                      child: approvalPicker!,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Who answers, and go — the wider of the two groups, and weighted to
          // say so. See [_leftFloor] for why the split isn't even.
          Flexible(
            flex: _rightFloor,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Agent then model, the two halves of "who answers, and with
                // what" — bounded (not fixed) so the pill sizes to the agent's
                // name while its inner label can still ellipsis.
                if (agentPicker != null) ...[
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 132),
                      child: agentPicker!,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // The pills are chips, not push buttons, so both sit at
                // heightSmall. This used to force a bare 30 — a fifth number in
                // a row that already had 32/32/28/32, and it silently overrode
                // the AppControl.height the picker itself asks for.
                //
                // The fixed 140 stays: a model pill that resized to each name
                // would make the row twitch on every switch. Under a tighter
                // box a `SizedBox` gives way to the box, which is the whole
                // point of putting it in a [Flexible].
                Flexible(child: SizedBox(width: 140, child: modelPicker)),
                const SizedBox(width: 4),
                _MicButton(
                  sending: sending,
                  messageController: messageController,
                  onSend: onSend,
                ),
                const SizedBox(width: 4),
                // Stop only gets its own button when Send has been taken over
                // by a follow-up going out mid-answer; the rest of the time the
                // one round button is both.
                if (sending && canSend) ...[
                  ComposerStopButton(onStop: onStop),
                  const SizedBox(width: 6),
                ],
                ComposerSendButton(
                  sending: sending,
                  canSend: canSend,
                  busyTooltip: busySendTooltip,
                  onSend: onSend,
                  onStop: onStop,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Takes a picture or a document onto the message being typed.
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.canAttach, required this.onAttach});

  final bool canAttach;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) => ComposerIconButton(
    icon: Icons.add_rounded,
    // What it takes, in the words of the person attaching it: pictures and
    // office files, or a paste of either. Full says how much fits rather than
    // going quiet.
    tooltip: canAttach
        ? 'Attach a picture or a document'
        : 'Up to $maxChatImages pictures and $maxChatFiles files',
    onPressed: canAttach ? onAttach : null,
  );
}

/// Opens the saved-prompt menu, or saves the current draft as a prompt.
///
/// One button with two honest jobs: with the box empty it browses prompts (drops
/// a `/` in to open the menu); with a draft typed it offers to keep that draft
/// for reuse. The icon and tooltip switch so the user knows which before tapping.
/// Opens the `/` command menu, by typing the slash the menu watches for — the
/// same keystroke the user could have made, so there is one way in and not two.
class _CommandsButton extends StatelessWidget {
  const _CommandsButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ComposerIconButton(
    icon: Icons.bolt_outlined,
    tooltip: 'Commands',
    onPressed: enabled ? onPressed : null,
  );
}

/// Tap to record, tap again to stop, transcribe and send — sits right beside
/// [ComposerSendButton] so voice input reads as another way to fill the same
/// box, not a separate feature bolted on elsewhere.
///
/// [VoiceShortcut] presses the same thing from the keyboard, and both go
/// through [pressVoiceInput] so the two presses can't come to mean different
/// things.
class _MicButton extends ConsumerWidget {
  const _MicButton({
    required this.sending,
    required this.messageController,
    required this.onSend,
  });

  final bool sending;
  final TextEditingController messageController;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads AppPalette.textSecondary — follow flips
    final phase = ref.watch(recordingControllerProvider);
    final recording = phase is RecordingActive;
    return Tooltip(
      message: voiceInputTooltip(phase),
      child: SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          iconSize: AppControl.iconSize,
          visualDensity: VisualDensity.compact,
          color: recording
              ? Theme.of(context).colorScheme.error
              : AppPalette.textSecondary,
          style: composerNoSplash,
          icon: switch (phase) {
            RecordingTranscribing() => const SizedBox(
              width: AppControl.iconSize,
              height: AppControl.iconSize,
              child: AppSpinner(size: SpinnerSize.small),
            ),
            RecordingActive() => const Icon(Icons.stop_rounded),
            RecordingIdle() ||
            RecordingFailed() => const Icon(Icons.mic_none_rounded),
          },
          onPressed: voiceInputBusy(phase, sending: sending)
              ? null
              : () => unawaited(
                  pressVoiceInput(
                    context,
                    ref,
                    controller: messageController,
                    onSend: onSend,
                  ),
                ),
        ),
      ),
    );
  }
}
