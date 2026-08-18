import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/composer_keys.dart';
import '../logic/recording_controller.dart';
import 'voice_input.dart';

/// The message composer — a multiline field, a mic button that transcribes a
/// voice clip straight into the field and sends it, and a circular send
/// button that spins while a request is in flight. [canSend] gates both
/// Enter-to-send and the send button (e.g. a video needs an attached image
/// first). Shared by the Playground dialog and the Chat tab.
class ChatInputBar extends StatelessWidget {
  const ChatInputBar({
    super.key,
    required this.controller,
    required this.sending,
    required this.canSend,
    required this.hint,
    required this.onSend,
    this.onPaste,
    this.prefix,
  });

  final TextEditingController controller;
  final bool sending;
  final bool canSend;
  final String hint;
  final VoidCallback onSend;

  /// Takes over ⌘V / Ctrl+V — how a pasted screenshot becomes an attachment
  /// instead of an empty keystroke. Null leaves paste to the field.
  final VoidCallback? onPaste;

  /// Optional leading action inside the field (e.g. the Chat composer's "+"
  /// image-attach button). Null in the Playground, which attaches via its bar.
  final Widget? prefix;

  @override
  Widget build(BuildContext context) {
    return VoiceShortcut(
      controller: controller,
      sending: sending,
      onSend: onSend,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: ComposerKeys(
              canSend: canSend,
              onSend: onSend,
              onPaste: onPaste,
              builder: (context, focusNode) => TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 5,
                enabled: !sending,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: hint,
                  filled: true,
                  fillColor: AppPalette.cardBg,
                  prefixIcon: prefix,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  border: _border(AppPalette.divider),
                  enabledBorder: _border(AppPalette.divider),
                  focusedBorder: _border(AppPalette.accent, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _MicButton(controller: controller, sending: sending, onSend: onSend),
          const SizedBox(width: 10),
          SizedBox(
            width: 48,
            height: 48,
            child: FilledButton(
              onPressed: canSend ? onSend : null,
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
              ),
              child: sending
                  ? const AppSpinner(size: SpinnerSize.large)
                  : const Icon(Icons.arrow_upward_rounded, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  OutlineInputBorder _border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );
}

/// Tap to record, tap again to stop, transcribe and send — a successful
/// non-empty transcript goes straight into [controller] and out through
/// [onSend], the same way a voice message sends itself once you let go.
///
/// [VoiceShortcut] does the same from the keyboard; both press
/// [pressVoiceInput].
class _MicButton extends ConsumerWidget {
  const _MicButton({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(recordingControllerProvider);
    final theme = Theme.of(context);
    final recording = phase is RecordingActive;
    return Tooltip(
      message: voiceInputTooltip(phase),
      child: SizedBox(
        width: 48,
        height: 48,
        child: OutlinedButton(
          onPressed: voiceInputBusy(phase, sending: sending)
              ? null
              : () => unawaited(
                  pressVoiceInput(
                    context,
                    ref,
                    controller: controller,
                    onSend: onSend,
                  ),
                ),
          style: OutlinedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            side: BorderSide(
              color: recording ? theme.colorScheme.error : AppPalette.divider,
            ),
          ),
          child: switch (phase) {
            RecordingTranscribing() => const AppSpinner(
              size: SpinnerSize.medium,
            ),
            RecordingActive() => Icon(
              Icons.stop_rounded,
              size: 20,
              color: theme.colorScheme.error,
            ),
            RecordingIdle() ||
            RecordingFailed() => const Icon(Icons.mic_none_rounded, size: 20),
          },
        ),
      ),
    );
  }
}
