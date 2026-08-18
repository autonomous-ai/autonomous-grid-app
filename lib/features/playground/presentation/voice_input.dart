import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/toast.dart';
import '../logic/recording_controller.dart';

/// The chord that presses the mic without reaching for it: ⌘⇧M on a Mac,
/// Ctrl+⇧M everywhere else.
///
/// Both are bound on every platform, the way the shell binds ⌘K and Ctrl+K for
/// the palette — it is [voiceInputShortcutLabel] that names the one this
/// keyboard actually has. Shift is not decoration: plain ⌘M minimizes the
/// window on macOS, so the chord without it would hide the app mid-sentence.
const kVoiceInputChords = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.keyM, meta: true, shift: true),
  SingleActivator(LogicalKeyboardKey.keyM, control: true, shift: true),
];

/// [kVoiceInputChords] spelled the way this platform spells it — a shortcut
/// nobody can read is a shortcut nobody presses, which is why it goes in the
/// mic's own tooltip rather than a page of key bindings.
String get voiceInputShortcutLabel =>
    defaultTargetPlatform == TargetPlatform.macOS ? '⌘⇧M' : 'Ctrl+Shift+M';

/// What the mic will do if pressed now, and the keys that press it.
///
/// The chord is left off while transcribing because pressing it then does
/// nothing — see [voiceInputBusy].
String voiceInputTooltip(RecordingPhase phase) => switch (phase) {
  RecordingActive() => 'Stop recording · $voiceInputShortcutLabel',
  RecordingTranscribing() => 'Transcribing…',
  RecordingIdle() ||
  RecordingFailed() => 'Voice input · $voiceInputShortcutLabel',
};

/// When voice input has nothing to offer: a clip is already being turned into
/// text, or the message this one would join is still going out.
///
/// One rule in one place, so the greyed-out button and the dead chord can never
/// disagree about whether the mic is available.
bool voiceInputBusy(RecordingPhase phase, {required bool sending}) =>
    sending || phase is RecordingTranscribing;

/// One press of voice input, from either the button or [kVoiceInputChords]:
/// start recording, or stop it and let the transcript go.
///
/// A finished transcript lands in [controller] and leaves through [onSend] —
/// speaking a message sends it, the way a voice note does. A failure is said
/// out loud as a toast, because the mic reverting to its idle icon explains
/// nothing about the permission that was refused.
Future<void> pressVoiceInput(
  BuildContext context,
  WidgetRef ref, {
  required TextEditingController controller,
  required VoidCallback onSend,
}) async {
  final transcript = await ref
      .read(recordingControllerProvider.notifier)
      .toggle();
  if (!context.mounted) return;
  if (ref.read(recordingControllerProvider) case RecordingFailed(
    :final message,
  )) {
    ToastScope.show(
      context,
      ToastSpec(message: message, severity: ToastSeverity.error),
    );
    return;
  }
  final text = transcript?.trim();
  if (text == null || text.isEmpty) return;
  controller.text = text;
  onSend();
}

/// Puts [kVoiceInputChords] over a composer, so the mic answers the keyboard
/// as well as the mouse.
///
/// It wraps the composer rather than living in the shell's app-wide bindings
/// because the transcript has to land in *this* box: a chord that fired on a
/// screen with no composer would record into nowhere.
///
/// The phase is read at the keystroke, never watched, so a recording starting
/// and stopping doesn't rebuild the composer around it — the mic button already
/// watches it to redraw itself.
class VoiceShortcut extends ConsumerWidget {
  const VoiceShortcut({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.child,
  });

  /// Where the transcript is written — the field this composer sends from.
  final TextEditingController controller;

  /// Whether a turn is already going out; the chord is dead while it is, the
  /// same as the button.
  final bool sending;

  final VoidCallback onSend;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CallbackShortcuts(
    bindings: {
      for (final chord in kVoiceInputChords) chord: () => _press(context, ref),
    },
    child: child,
  );

  void _press(BuildContext context, WidgetRef ref) {
    final phase = ref.read(recordingControllerProvider);
    if (voiceInputBusy(phase, sending: sending)) return;
    unawaited(
      pressVoiceInput(context, ref, controller: controller, onSend: onSend),
    );
  }
}
