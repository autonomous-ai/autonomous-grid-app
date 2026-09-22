/// Brings sharing with a phone back up if it was on when the app last closed.
///
/// Wraps the app rather than sitting inside it, like [TelegramBotScope] and for
/// the same reason: a phone reaches this computer whichever screen the window
/// happens to be on, and the link cannot wait for somebody to open Settings ▸
/// Phone before it exists.
///
/// Without this sharing went back to off on every launch. On the phone that was
/// indistinguishable from a computer that was asleep — "Can't reach your
/// computer" next to an open Grid, and a Try again that could never work.
///
/// It only ever *restores* a choice. A computer that has never shared with a
/// phone opens no port and publishes no address, however often it is launched
/// (`PhoneLinkPrefs`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/phone/logic/phone_sharing_controller.dart';

/// Resumes the phone link, once, after the first frame.
class PhoneLinkScope extends ConsumerStatefulWidget {
  const PhoneLinkScope({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  ConsumerState<PhoneLinkScope> createState() => _PhoneLinkScopeState();
}

class _PhoneLinkScopeState extends ConsumerState<PhoneLinkScope> {
  @override
  void initState() {
    super.initState();
    // After the first frame: nobody is waiting on a relay to draw the window.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(phoneSharingProvider.notifier).resume());
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keeps the controller alive for the life of the app. Riverpod 3 pauses a
    // provider nothing is listening to, and a paused controller is one that
    // stops noticing its tunnel died the moment the Phone screen is closed.
    ref.listen(phoneSharingProvider, (_, _) {});
    return widget.child;
  }
}
