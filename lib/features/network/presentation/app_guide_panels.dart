import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/app_guide_snippets.dart';
import '../logic/client_app_configurator.dart';
import '../logic/client_app_detector.dart';
import 'detail_widgets.dart';

/// Where the "Apply for me" write is in its lifecycle for the selected app.
sealed class ApplyPhase {
  const ApplyPhase();
}

class ApplyIdle extends ApplyPhase {
  const ApplyIdle();
}

class ApplyRunning extends ApplyPhase {
  const ApplyRunning();
}

class ApplyDone extends ApplyPhase {
  const ApplyDone(this.result);
  final ApplyResult result;
}

/// Setup for one known client: a Download prompt when it's missing, the config
/// snippet(s), and — when installed — an "Apply for me" button with its result.
class ClientAppPanel extends StatelessWidget {
  const ClientAppPanel({
    super.key,
    required this.info,
    required this.installed,
    required this.baseUrl,
    required this.apiKey,
    required this.phase,
    required this.onApply,
    required this.onDownload,
  });

  final ClientAppInfo info;
  final bool installed;
  final String baseUrl;
  final String apiKey;
  final ApplyPhase phase;
  final VoidCallback onApply;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!installed) ...[
          _NotInstalledBanner(name: info.name, onDownload: onDownload),
          const SizedBox(height: 14),
        ],
        ..._configBlocks(),
        if (installed) ...[
          const SizedBox(height: 12),
          _ApplyRow(name: info.name, phase: phase, onApply: onApply),
          _ApplyStatus(phase: phase),
        ],
      ],
    );
  }

  List<Widget> _configBlocks() {
    switch (info.app) {
      case ClientApp.openClaw:
        return [
          GuideLabel(info.name, caption: 'Add to ${info.configPath}'),
          CodeBlock(code: openClawSnippet(baseUrl, apiKey)),
        ];
      case ClientApp.hermes:
        return [
          const GuideLabel('Endpoint', caption: 'In ~/.hermes/config.yaml'),
          CodeBlock(code: hermesConfigSnippet(baseUrl)),
          const SizedBox(height: 10),
          const GuideLabel('API key', caption: 'Add to ~/.hermes/.env'),
          CodeBlock(code: hermesEnvSnippet(apiKey)),
        ];
    }
  }
}

/// Fallback for any app we don't detect: the raw OpenAI-compatible pair plus a
/// tiny SDK example — enough to wire up anything by hand.
class OtherAppPanel extends StatelessWidget {
  const OtherAppPanel({super.key, required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GuideLabel('Any OpenAI-compatible app',
            caption: 'point it at these two values'),
        CodeBlock(code: envSnippet(baseUrl, apiKey)),
        const SizedBox(height: 14),
        const GuideLabel('Example (Python)',
            caption: 'works with any OpenAI SDK'),
        CodeBlock(code: pythonSnippet(baseUrl, apiKey)),
        const SizedBox(height: 14),
        Text(
          'Replace $kGuideDefaultModel with a model your grid serves. Every '
          'model on every machine answers at this one endpoint.',
          style: const TextStyle(
              color: AppPalette.textFaint, fontSize: 12, height: 1.45),
        ),
      ],
    );
  }
}

/// The "you don't have this yet" prompt with a Download button.
class _NotInstalledBanner extends StatelessWidget {
  const _NotInstalledBanner({required this.name, required this.onDownload});

  final String name;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "You don't have $name yet. Install it, then Grid can set it up.",
            style: const TextStyle(
                color: AppPalette.textSecondary, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: onDownload,
            icon: const Icon(Icons.download_rounded, size: 16),
            label: Text('Download $name'),
          ),
        ],
      ),
    );
  }
}

/// The "Apply for me" action — writes the config so the user doesn't touch a
/// file. Shows a spinner while writing.
class _ApplyRow extends StatelessWidget {
  const _ApplyRow(
      {required this.name, required this.phase, required this.onApply});

  final String name;
  final ApplyPhase phase;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final running = phase is ApplyRunning;
    return Row(
      children: [
        FilledButton.icon(
          onPressed: running ? null : onApply,
          icon: running
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_fix_high_rounded, size: 16),
          label: Text(running ? 'Applying…' : 'Apply for me'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Writes it into $name for you (a backup is kept).',
            style: const TextStyle(color: AppPalette.textFaint, fontSize: 11.5),
          ),
        ),
      ],
    );
  }
}

/// The result line after "Apply for me": success (green) with any follow-up
/// note, or a failure (red) telling the user to Copy the config instead.
class _ApplyStatus extends StatelessWidget {
  const _ApplyStatus({required this.phase});

  final ApplyPhase phase;

  @override
  Widget build(BuildContext context) {
    final phase = this.phase;
    if (phase is! ApplyDone) return const SizedBox.shrink();
    return switch (phase.result) {
      ApplyOk(:final message, :final note) => _StatusLine(
          icon: Icons.check_circle_rounded,
          color: AppPalette.online,
          text: note == null ? message : '$message $note',
        ),
      ApplyError(:final message) => _StatusLine(
          icon: Icons.error_outline_rounded,
          color: Theme.of(context).colorScheme.error,
          text: '$message Copy the config above and paste it in yourself.',
        ),
    };
  }
}

/// One icon + wrapped message line, used for the apply result.
class _StatusLine extends StatelessWidget {
  const _StatusLine(
      {required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
