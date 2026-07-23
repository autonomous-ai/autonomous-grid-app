import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_environment.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/log_view.dart';
import '../../playground/presentation/playground_dialog.dart';
import '../logic/api_engine_catalog.dart';
import '../logic/provider_run_controller.dart';
import '../logic/serving_engines_provider.dart';
import 'serving_engine_tile.dart';
import 'stop_engine_dialog.dart';

/// What this machine is serving on the active grid: one row per engine in its
/// union (ADR 0010), each stoppable on its own, plus a transient "starting" row
/// while a new engine joins. One place to try the models and read the engine
/// log. Only shown when something is serving or starting — see `ProviderView`.
class ServingEnginesSection extends ConsumerWidget {
  const ServingEnginesSection({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engines = ref.watch(servingEnginesProvider);
    final run = ref.watch(providerRunControllerProvider);
    final active = run is ProviderRunActive && run.grid == network.networkId
        ? run
        : null;
    final starting = active?.starting ?? false;
    final signInUrl = active?.signInUrl;
    final log = active?.log ?? const <String>[];
    final stopping =
        run is ProviderRunStopping && run.grid == network.networkId;

    // Any non-responses model in the union can be tried in-app; a codex seat
    // can't (the Playground speaks chat/completions), so the hint drops then.
    final unionModels = [
      for (final engine in engines) ...engine.models,
    ].join(',');
    final canPlayground =
        engines.isNotEmpty && !isResponsesOnlyModel(unionModels);

    return GlassCard(
      style: GlassCardStyle.hero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            gridName: network.name,
            activity: _activity(
              engines,
              starting: starting,
              stopping: stopping,
            ),
            onStop: () => _stop(context, ref, engines),
          ),
          for (final engine in engines)
            ServingEngineTile(
              engine: engine,
              gridId: network.networkId,
              stopping: stopping,
            ),
          if (signInUrl != null) ...[
            const SizedBox(height: 12),
            _SignInPrompt(url: signInUrl),
          ],
          if (canPlayground) ...[
            const SizedBox(height: 12),
            _PlaygroundHint(onOpen: () => openPlaygroundDialog(context, ref)),
          ],
          // Developer builds only: the engine's raw output is diagnostics, and
          // the row sat under the serving card all day offering people who
          // don't read logs a drawer of llama.cpp chatter. Nothing is lost —
          // the same lines are in `~/.grid/logs` and the Debug tab.
          if (log.isNotEmpty && AppEnvironment.isDeveloperMode) ...[
            const SizedBox(height: 12),
            _LogExpander(lines: log),
          ],
        ],
      ),
    );
  }

  /// What the header reports. A stop in flight outranks the rest: the engine is
  /// still up and still listed, but the only true thing to say about it is that
  /// it's on its way out.
  _Activity _activity(
    List<ServingEngine> engines, {
    required bool starting,
    required bool stopping,
  }) {
    if (stopping) return _Activity.stopping;
    if (engines.isNotEmpty) return _Activity.serving;
    return _Activity.starting;
  }

  /// Stop what this machine is serving — after the same question the row's own
  /// Stop asks, and in the same words. Cancelling a join that hasn't produced an
  /// engine yet skips it: nothing is on the grid to be taken away.
  Future<void> _stop(
    BuildContext context,
    WidgetRef ref,
    List<ServingEngine> engines,
  ) async {
    final notifier = ref.read(providerRunControllerProvider.notifier);
    if (engines.isEmpty) return notifier.stop();
    final ok = await confirmStopEngine(
      context,
      what: engines.length == 1
          ? engineTitle(engines.first)
          : 'all ${engines.length} engines',
    );
    if (!ok) return;
    await notifier.stop();
  }
}

/// What this machine is doing on the grid right now — the three things the
/// header can honestly say, and one word for each so the icon, the sentence and
/// the button can't disagree.
enum _Activity { starting, serving, stopping }

/// The section header: the activity, and the one control that ends it.
///
/// Every state is named for what is true at that moment. It says *Starting*
/// while a join is in flight, never *Serving* — with nothing live yet, "Serving
/// on autonomous.ai" over a spinner claimed a share that hadn't happened. And
/// *Stopping* until `grid leave` returns, which takes seconds: the row used to
/// keep its green dot and its live Stop throughout, so the only feedback a
/// second click gave was that nothing happened.
class _Header extends StatelessWidget {
  const _Header({
    required this.gridName,
    required this.activity,
    required this.onStop,
  });

  final String gridName;
  final _Activity activity;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final serving = activity == _Activity.serving;
    return Row(
      children: [
        serving
            ? Icon(Icons.dns, color: AppPalette.online, size: 18)
            : const AppSpinner(),
        const SizedBox(width: 10),
        Expanded(
          child: Text(switch (activity) {
            _Activity.starting => 'Starting on $gridName…',
            _Activity.serving => 'Serving on $gridName',
            _Activity.stopping => 'Stopping on $gridName…',
          }, style: theme.textTheme.titleMedium),
        ),
        // Nothing to press while it's already stopping — a second leave would
        // race the first, and there is no state left to ask for.
        if (activity != _Activity.stopping)
          TextButton.icon(
            onPressed: onStop,
            icon: Icon(serving ? Icons.stop : Icons.close, size: 18),
            label: Text(serving ? 'Stop' : 'Cancel'),
          ),
      ],
    );
  }
}

/// A compact nudge to try the running models in the Playground.
class _PlaygroundHint extends StatelessWidget {
  const _PlaygroundHint({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: AppPalette.online, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Others on the grid can use these now. Try them yourself in the '
              'Playground.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.chat_bubble_outline, size: 16),
            label: const Text('Playground'),
          ),
        ],
      ),
    );
  }
}

/// The engine log, collapsed by default — real detail for when something looks
/// wrong, out of the way when it doesn't.
class _LogExpander extends StatelessWidget {
  const _LogExpander({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8),
        title: Text('Activity log', style: theme.textTheme.bodyMedium),
        children: [SizedBox(height: 200, child: LogView(lines: lines))],
      ),
    );
  }
}

/// Shown while a sign-in join (codex OAuth) waits for browser approval. The app
/// already opened the browser; this confirms what to do and offers a fallback
/// link in case it didn't open.
class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt({required this.url});

  final String url;

  Future<void> _open() async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.open_in_browser,
            color: theme.colorScheme.primary,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Approve the sign-in in your browser',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'Once you approve, sharing starts automatically. Didn’t open?',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _open,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open sign-in page'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
