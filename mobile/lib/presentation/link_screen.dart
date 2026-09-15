/// The whole app, one screen wide.
///
/// Every branch of the link's state gets a case here, and the compiler checks
/// the set is complete — which is the point of the sealed type: a state nobody
/// drew is a blank screen with no way out of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/pairing_links.dart';
import '../logic/phone_chats.dart';
import '../logic/phone_link_controller.dart';
import 'connected_view.dart';
import 'pair_form.dart';

/// Grid's only screen.
class LinkScreen extends ConsumerStatefulWidget {
  const LinkScreen({super.key});

  @override
  ConsumerState<LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends ConsumerState<LinkScreen> {
  @override
  void initState() {
    super.initState();
    // Not in build(): reconnecting is a side effect, and build runs again for
    // reasons that have nothing to do with wanting a second connection.
    PairingLinks.listen(
      (link) => ref.read(phoneLinkProvider.notifier).pair(link),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final launchedWith = PairingLinks.initial();
      final link = ref.read(phoneLinkProvider.notifier);
      // A link beats whatever is stored: someone who just scanned a code meant
      // to use that computer, not the one this phone happened to remember.
      if (launchedWith != null) {
        link.pair(launchedWith);
        return;
      }
      link.restore();
    });
  }

  /// Re-asks the computer everything this screen shows.
  ///
  /// The chats are their own providers rather than part of the link's state, so
  /// refreshing the link alone would leave the list on screen exactly as stale
  /// as it was — the one thing a refresh button must not do. Invalidating is
  /// what re-asks them; it happens here rather than in the controller because
  /// the chat providers read *it*, and a controller reaching back into them
  /// would be a cycle.
  void _refresh(WidgetRef ref) {
    ref.read(phoneLinkProvider.notifier).refresh();
    ref.invalidate(chatListProvider);
    ref.invalidate(projectsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final link = ref.watch(phoneLinkProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grid'),
        actions: [
          if (link is PhoneLinkConnected)
            IconButton(
              tooltip: 'Refresh',
              onPressed: () => _refresh(ref),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: SafeArea(
        child: switch (link) {
          PhoneLinkUnpaired() => const _Padded(PairForm()),
          PhoneLinkConnecting(:final step) => _Working(step),
          PhoneLinkConnected() => ConnectedView(link),
          PhoneLinkFailed(:final message, :final stillPaired) =>
            stillPaired
                ? _Padded(_Stuck(message))
                : _Padded(PairForm(problem: message)),
        },
      ),
    );
  }
}

class _Padded extends StatelessWidget {
  const _Padded(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(padding: const EdgeInsets.all(24), child: child);
}

class _Working extends StatelessWidget {
  const _Working(this.step);

  final String step;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
        const SizedBox(height: 18),
        // The step, not a generic spinner: when this takes a while, which half
        // it is stuck in is the only useful thing on the screen.
        Text(step, style: Theme.of(context).textTheme.bodyMedium),
      ],
    ),
  );
}

/// Paired, but not connected. Offers the action that might fix it.
class _Stuck extends ConsumerWidget {
  const _Stuck(this.message);

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("Can't reach your computer", style: theme.textTheme.headlineSmall),
        const SizedBox(height: 10),
        Text(message, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => ref.read(phoneLinkProvider.notifier).reconnect(),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Try again'),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => ref.read(phoneLinkProvider.notifier).unpair(),
          child: const Text('Use a different pairing code'),
        ),
      ],
    );
  }
}
