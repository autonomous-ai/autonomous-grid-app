import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/labeled_field.dart';
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

  void _pull() =>
      ref.read(modelPullControllerProvider.notifier).pull(_spec.text);

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
          // 13pt explicitly: InputDecorationTheme has no `style` slot, so a bare
          // TextField takes Material's 16pt and stands out beside every other
          // field in the app.
          style: kFieldTextStyle,
          decoration: labeledFieldDecoration(
            'unsloth/…-GGUF:…-00001-of-00005.gguf',
            fill: AppCard.inset,
          ),
        ),
        const SizedBox(height: 6),
        // The whole instruction, in one line. It used to run to three: the
        // format, then "for a split model, paste every part", then a warning
        // that models are large and download in the background. "One line per
        // file" says the second in four words, and the first two are answered
        // by what the user is already looking at — the shelf above prints each
        // model's size, and pressing Download swaps this for a progress bar
        // with a Cancel beside it.
        Text(
          'owner/repo:file.gguf — one line per file',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (state is ModelPullDone) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.check_circle, color: AppPalette.online, size: 18),
              const SizedBox(width: 8),
              // What landed and what to do about it, in one sentence rather
              // than a line of confirmation followed by a line of instruction.
              Expanded(child: Text('${state.file} — close this to start it.')),
            ],
          ),
        ],
        if (state is ModelPullFailed) ...[
          const SizedBox(height: 8),
          Text(
            state.message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 14),
        // The action leads, the way to go and find something to paste follows
        // it on the same row — one strip instead of a link and a button with a
        // paragraph between them.
        Row(
          children: [
            ListenableBuilder(
              listenable: _spec,
              builder: (context, _) => FilledButton.icon(
                onPressed: _spec.text.trim().isEmpty ? null : _pull,
                icon: const Icon(
                  Icons.download_outlined,
                  size: AppControl.iconSize,
                ),
                label: Text(
                  state is ModelPullFailed ? 'Try again' : 'Download',
                ),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(_huggingFaceGgufUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new, size: AppControl.iconSize),
              // The tile above already said Hugging Face; repeating it here
              // spent half the label saying where the user already knows they
              // are.
              label: const Text('Browse models'),
              style: TextButton.styleFrom(
                padding: AppControl.paddingSmall,
                minimumSize: const Size(0, AppControl.heightSmall),
              ),
            ),
          ],
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
    final fraction = (progress != null && !progress.isIndeterminate)
        ? progress.pct! / 100
        : null;

    final label = switch (progress) {
      null => 'Starting download…',
      _ when progress.isIndeterminate =>
        '${progress.doneMb.toStringAsFixed(1)} MB',
      _ =>
        '${progress.doneMb.toStringAsFixed(1)} / '
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
            Expanded(child: Text(heading, style: theme.textTheme.bodyMedium)),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () =>
                  ref.read(modelPullControllerProvider.notifier).cancel(),
              icon: const Icon(Icons.close, size: AppControl.iconSize),
              label: const Text('Cancel'),
              // Inline beside the progress heading; the error colour marks it as
              // the destructive way out of a running download.
              style: TextButton.styleFrom(
                minimumSize: const Size(0, AppControl.heightSmall),
                padding: AppControl.paddingSmall,
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          state.spec,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        AppProgressBar(value: fraction),
        const SizedBox(height: 6),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
