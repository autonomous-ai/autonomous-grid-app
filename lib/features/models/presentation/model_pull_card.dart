import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logic/model_pull_controller.dart';

/// Where to find GGUF models to paste into the download field.
const _huggingFaceGgufUrl =
    'https://huggingface.co/models?library=gguf&sort=trending';

/// Step 3 of the provider flow: pull a GGUF model from Hugging Face into
/// `~/.grid/models` via `grid models pull <repo>:<file>`, with a live bar.
class ModelPullCard extends ConsumerStatefulWidget {
  const ModelPullCard({super.key});

  @override
  ConsumerState<ModelPullCard> createState() => _ModelPullCardState();
}

class _ModelPullCardState extends ConsumerState<ModelPullCard> {
  // Prefilled with the reference Qwen model so the flow is one click to try.
  final _spec = TextEditingController(
    text: 'unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-IQ3_S.gguf',
  );

  @override
  void dispose() {
    _spec.dispose();
    super.dispose();
  }

  void _pull() => ref.read(modelPullControllerProvider.notifier).pull(_spec.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(modelPullControllerProvider);

    if (state is ModelPulling) {
      return _ProgressView(state: state);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _spec,
          minLines: 1,
          maxLines: 6,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            labelText: 'Model to download',
            helperText: 'Format  owner/repo:file.gguf — one per line. For a '
                'split model, paste every part.',
            helperMaxLines: 2,
            hintText: 'unsloth/…-GGUF:…-00001-of-00005.gguf',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(_huggingFaceGgufUrl),
                mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new, size: 15),
            label: const Text('Browse models on Hugging Face'),
            style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12.5)),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Models are large — often several GB — and download in the background.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (state is ModelPullDone) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.check_circle, color: AppPalette.online, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text('Downloaded ${state.file}')),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Ready to use. Close this, then start the engine to serve it.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        if (state is ModelPullFailed) ...[
          const SizedBox(height: 8),
          Text(state.message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ListenableBuilder(
            listenable: _spec,
            builder: (context, _) => FilledButton.icon(
              onPressed: _spec.text.trim().isEmpty ? null : _pull,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(state is ModelPullFailed ? 'Try again' : 'Download'),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProgressView extends ConsumerWidget {
  const _ProgressView({required this.state});
  final ModelPulling state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final progress = state.progress;
    final fraction =
        (progress != null && !progress.isIndeterminate) ? progress.pct! / 100 : null;

    final label = switch (progress) {
      null => 'Starting download…',
      _ when progress.isIndeterminate =>
        '${progress.doneMb.toStringAsFixed(1)} MB',
      _ => '${progress.doneMb.toStringAsFixed(1)} / '
          '${progress.totalMb!.toStringAsFixed(1)} MB '
          '(${progress.pct!.toStringAsFixed(1)}%)',
    };

    final multi = state.total > 1;
    final heading = multi
        ? 'Downloading part ${state.current} of ${state.total}'
        : 'Downloading a model';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(heading, style: theme.textTheme.bodyMedium),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () =>
                  ref.read(modelPullControllerProvider.notifier).cancel(),
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Cancel'),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: theme.colorScheme.error),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(state.spec,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 10),
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 6),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
