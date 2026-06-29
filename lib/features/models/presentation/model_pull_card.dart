import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
          decoration: const InputDecoration(
            labelText: 'Model to download',
            helperText: 'A model in the format  owner/repo:file.gguf',
            hintText: 'unsloth/…-GGUF:…IQ3_S.gguf',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 6),
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
        Text(
          'Models are large — often several GB — and download in the background.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (state is ModelPullDone) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 18),
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
        const SizedBox(height: 12),
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

class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.state});
  final ModelPulling state;

  @override
  Widget build(BuildContext context) {
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Downloading ${state.spec}',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 10),
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 6),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
