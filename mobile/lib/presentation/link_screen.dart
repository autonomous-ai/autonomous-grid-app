/// The whole app, one screen wide.
///
/// Every branch of the link's state gets a case here, and the compiler checks
/// the set is complete — which is the point of the sealed type: a state nobody
/// drew is a blank screen with no way out of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/pairing_links.dart';
import '../logic/phone_link_controller.dart';
import 'grid_app_bar.dart';
import 'home_shell.dart';
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

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return switch (ref.watch(phoneLinkProvider)) {
      // Connected is the whole app, frame and all — four tabs, a bar, and a
      // title that changes with them — so it brings its own [Scaffold] rather
      // than being poured into the one the other three states share.
      final PhoneLinkConnected connected => HomeShell(connected),
      PhoneLinkUnpaired() => _frame(const _Padded(PairForm())),
      PhoneLinkConnecting(:final step) => _frame(_Working(step)),
      PhoneLinkFailed(:final message, :final stillPaired) => _frame(
        stillPaired
            ? _Padded(_Stuck(message))
            : _Padded(PairForm(problem: message)),
      ),
    };
  }

  /// The plain screen the three unconnected states share: the app's name, and
  /// whatever it has to say about not being through yet.
  Widget _frame(Widget child) => Scaffold(
    backgroundColor: AppPalette.windowBg,
    appBar: const GridAppBar(title: 'Grid'),
    body: SafeArea(child: child),
  );
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
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppPalette.accentOnSurface,
            ),
          ),
          const SizedBox(height: 16),
          // The step, not a generic spinner: when this takes a while, which
          // half it is stuck in is the only useful thing on the screen.
          Text(
            step,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Paired, but not connected. Offers the action that might fix it.
class _Stuck extends ConsumerWidget {
  const _Stuck(this.message);

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("Can't reach your computer", style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          // Taller than the shared 32, and deliberately: that number is a
          // *pointer* target on a desktop. Apple asks for 44 under a thumb, and
          // a 32px primary action on a phone is a button people miss.
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          onPressed: () => ref.read(phoneLinkProvider.notifier).reconnect(),
          child: const Text('Try again'),
        ),
        const SizedBox(height: 8),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          onPressed: () => ref.read(phoneLinkProvider.notifier).unpair(),
          child: const Text('Use a different code'),
        ),
      ],
    );
  }
}
