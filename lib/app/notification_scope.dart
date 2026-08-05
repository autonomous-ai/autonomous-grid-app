import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infrastructure/platform/desktop_notifier.dart';
import '../shared/layouts/reveal_chat.dart';

/// Takes the user where a clicked notification promised to take them.
///
/// The posting side lives wherever the work finishes (a delivered task result, a
/// finished agent turn); this is the other half — without it a banner is a beep
/// that does nothing when clicked, which teaches people to ignore banners.
///
/// Wraps the app rather than sitting inside a screen: a notification can be
/// clicked while the user is on Settings, or with the window hidden entirely.
/// Renders [child] unchanged.
class NotificationScope extends ConsumerStatefulWidget {
  const NotificationScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NotificationScope> createState() => _NotificationScopeState();
}

class _NotificationScopeState extends ConsumerState<NotificationScope> {
  StreamSubscription<String>? _clicks;

  @override
  void initState() {
    super.initState();
    // Not in `build`: subscribing there would re-subscribe on every rebuild, and
    // a stream listen is a side effect (§2).
    _clicks = ref
        .read(desktopNotifierProvider)
        .opened
        .listen((chatId) => unawaited(revealChat(ref, chatId)));
  }

  @override
  void dispose() {
    unawaited(_clicks?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
