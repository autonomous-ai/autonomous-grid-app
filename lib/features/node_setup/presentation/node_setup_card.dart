import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../../shared/widgets/log_view.dart';
import '../logic/node_capabilities.dart';
import '../logic/node_setup_controller.dart';
import '../logic/node_setup_plan.dart';

/// "This computer as a node" — detects what inference this machine can already
/// do, previews the gap-filling install/download plan, and runs it on one click
/// with a live log. The idle view is driven by detected capabilities; once
/// started, the [NodeSetupController] state takes over.
class NodeSetupCard extends ConsumerWidget {
  const NodeSetupCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setup = ref.watch(nodeSetupControllerProvider);

    final Widget body = switch (setup) {
      NodeSetupRunning() => _RunningBody(state: setup),
      NodeSetupFailed() => _FailedBody(state: setup),
      NodeSetupDone() => _DoneBody(state: setup),
      NodeSetupIdle() => const _IdleBody(),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.hub_outlined),
                const SizedBox(width: 8),
                Text('This computer as a node',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            body,
          ],
        ),
      ),
    );
  }
}

class _IdleBody extends ConsumerWidget {
  const _IdleBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(nodeCapabilitiesProvider);
    return caps.when(
      loading: () => const Row(
        children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Inspecting this computer…'),
        ],
      ),
      error: (e, _) => Text("Couldn't inspect this computer: $e"),
      data: (c) => _PlanPreview(caps: c),
    );
  }
}

/// Detected capabilities + the minimal plan to fill the gaps, with a single
/// button to run it. When nothing is missing, just confirms the node is ready.
class _PlanPreview extends ConsumerWidget {
  const _PlanPreview({required this.caps});
  final NodeCapabilities caps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final plan = buildSetupPlan(caps);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CapabilitySummary(caps: caps),
        const SizedBox(height: 16),
        if (plan.isEmpty)
          const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 18),
              SizedBox(width: 8),
              Expanded(
                  child: Text('This computer is ready to serve as a node.')),
            ],
          )
        else ...[
          Text("We'll install only what's missing:",
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final step in plan) _StepTile(step: step),
          const SizedBox(height: 8),
          Text('Downloads can be several GB; they run while the app stays open.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () =>
                  ref.read(nodeSetupControllerProvider.notifier).run(plan),
              icon: const Icon(Icons.rocket_launch_outlined),
              label: const Text('Set up this computer'),
            ),
          ),
        ],
      ],
    );
  }
}

class _CapabilitySummary extends StatelessWidget {
  const _CapabilitySummary({required this.caps});
  final NodeCapabilities caps;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _CapChip(
          ok: caps.hasTextInference,
          label: caps.hasTextInference
              ? 'Text · ${caps.textBackendLabel}'
              : 'Text · none',
        ),
        _CapChip(
          ok: caps.hasMediaEngine,
          label: caps.hasMediaEngine ? 'Media · ComfyUI' : 'Media · none',
        ),
        _CapChip(
          ok: caps.hasModels,
          label: '${caps.localModelCount} local model(s)',
        ),
      ],
    );
  }
}

class _CapChip extends StatelessWidget {
  const _CapChip({required this.ok, required this.label});
  final bool ok;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        ok ? Icons.check_circle : Icons.remove_circle_outline,
        size: 16,
        color: ok ? Colors.green : Theme.of(context).colorScheme.outline,
      ),
      label: Text(label),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step});
  final SetupStep step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(step.isDownload ? Icons.download_outlined : Icons.build_outlined,
              size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.title, style: theme.textTheme.bodyMedium),
                Text(step.detail,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RunningBody extends ConsumerWidget {
  const _RunningBody({required this.state});
  final NodeSetupRunning state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final progress = state.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Step ${state.index + 1}/${state.steps.length}: '
                '${state.current.title}',
              ),
            ),
            TextButton(
              onPressed: () =>
                  ref.read(nodeSetupControllerProvider.notifier).cancel(),
              child: const Text('Cancel'),
            ),
          ],
        ),
        if (progress != null) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
              value: progress.isIndeterminate ? null : progress.pct! / 100),
          const SizedBox(height: 4),
          Text(_progressLabel(progress), style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 12),
        SizedBox(height: 240, child: LogView(lines: state.log)),
      ],
    );
  }

  String _progressLabel(DownloadProgress p) {
    if (p.totalMb == null) return '${p.doneMb.toStringAsFixed(0)} MB';
    final pct = p.pct == null ? '' : ' (${p.pct!.toStringAsFixed(0)}%)';
    return '${p.doneMb.toStringAsFixed(0)} / ${p.totalMb!.toStringAsFixed(0)} MB$pct';
  }
}

class _FailedBody extends ConsumerWidget {
  const _FailedBody({required this.state});
  final NodeSetupFailed state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Setup stopped at "${state.step.title}"',
                  style: theme.textTheme.titleSmall),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(state.message,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error)),
        if (state.log.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(height: 160, child: LogView(lines: state.log)),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () =>
                ref.read(nodeSetupControllerProvider.notifier).reset(),
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ),
      ],
    );
  }
}

class _DoneBody extends ConsumerWidget {
  const _DoneBody({required this.state});
  final NodeSetupDone state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final completed = state.completed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                completed.isEmpty
                    ? 'This computer was already set up as a node.'
                    : 'Done — this computer is set up as a node.',
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
        for (final step in completed)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const Icon(Icons.check, size: 16, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(step.title, style: theme.textTheme.bodySmall)),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () =>
                ref.read(nodeSetupControllerProvider.notifier).reset(),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}
