import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/chrome_setup_controller.dart';

/// Connects the Claude in Chrome extension to Claude Code at launch, so the
/// assistant can drive the browser the user already has open.
///
/// The Claude desktop app does exactly this — its native messaging manifest is
/// rewritten every time it starts — and until now Grid did not: the connection
/// only appeared if somebody found "Connect my Chrome" on the Agents screen and
/// spent a model turn on it. What people saw instead was an assistant that
/// talked about the browser and never opened one.
///
/// A widget rather than a call in `main()` for the reason [GridSkillsScope] is
/// one: it is read from providers, and the `ProviderScope` they live in only
/// exists inside the tree. It draws nothing and rebuilds nothing — [child]
/// passes straight through.
///
/// Silent by design. It writes two small files, opens no browser, asks no
/// model, and says nothing on screen: the Agents card reads the machine
/// afterwards and reports what it finds.
class ChromeConnectScope extends ConsumerStatefulWidget {
  const ChromeConnectScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ChromeConnectScope> createState() => _ChromeConnectScopeState();
}

class _ChromeConnectScopeState extends ConsumerState<ChromeConnectScope> {
  @override
  void initState() {
    super.initState();
    // After the first frame: this touches the disk, and the window should not
    // wait on it. `announce: false` keeps a launch that had nothing to do from
    // opening the card with a message nobody asked for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(chromeSetupProvider.notifier).connect(announce: false);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
