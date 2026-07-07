import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/app_guide_snippets.dart';
import '../logic/client_app_configurator.dart';
import '../logic/client_app_detector.dart';
import '../logic/grid_overview_provider.dart';
import 'detail_widgets.dart';

/// Where the "Set up for me" write is in its lifecycle for the selected app.
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

/// Setup for one known client: the grid's Base URL + API Key as copyable fields,
/// a one-tap "Set up for me" that writes the connection into the app's config
/// (chat grids only — see [_ApplyBlock]), the exact config block as the manual
/// fallback, and a Download prompt when the app is missing.
///
/// A media grid (image/video) can't be wired as a chat "custom endpoint" nor be
/// the app's model, so instead of the chat setup + Apply it shows a "build a
/// skill" prompt (and a note that the agent needs its own chat model first) —
/// see [media] / [hasChat]. A grid that serves both keeps the chat setup/Apply
/// and appends the media prompt.
class ClientAppPanel extends StatelessWidget {
  const ClientAppPanel({
    super.key,
    required this.info,
    required this.installed,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.media,
    required this.hasChat,
    required this.phase,
    required this.onApply,
    required this.onOpenSite,
  });

  final ClientAppInfo info;
  final bool installed;
  final String baseUrl;
  final String apiKey;

  /// The model the grid actually serves (or the fallback default), wired into
  /// the snippet so it names a model the grid can answer.
  final String model;

  /// What the grid can generate — drives the "build a skill" media prompt.
  final GridMediaCapabilities media;

  /// Whether the grid serves a real chat model. False + [media] present means a
  /// media-only grid, where the chat "custom endpoint" setup doesn't apply.
  final bool hasChat;

  /// Lifecycle of the "Set up for me" write (idle/running/done result).
  final ApplyPhase phase;

  /// Writes this grid's connection into the app's config for the user.
  final VoidCallback onApply;

  /// Opens the app's official site — the Download target when missing, and the
  /// "docs" affordance otherwise.
  final VoidCallback onOpenSite;

  @override
  Widget build(BuildContext context) {
    // Show chat setup for a chat grid, or while the overview still loads (media
    // resolves to none first) — so a chat grid never flashes without its steps.
    final showChat = hasChat || !media.any;
    // One-click config write only makes sense when the grid can be the app's
    // model (a chat grid) and the app is actually installed to write into.
    final canApply = installed && hasChat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!installed) ...[
          _MissingAppNote(name: info.name, onDownload: onOpenSite),
          const SizedBox(height: 16),
        ],
        ConnectionFields(baseUrl: baseUrl, apiKey: apiKey),
        const SizedBox(height: 16),
        if (canApply) ...[
          _ApplyBlock(name: info.name, phase: phase, onApply: onApply),
          const SizedBox(height: 16),
        ],
        if (showChat) ...[
          ..._chatSetup(),
          const SizedBox(height: 16),
        ],
        if (media.any) ...[
          // A media-only grid can't be the app's chat model, so the agent still
          // needs its own model before it can build the skill — say so plainly.
          if (!hasChat) ...[
            _NeedsChatModelNote(
                appName: info.name, command: info.executable),
            const SizedBox(height: 12),
          ],
          _MediaSkillPrompt(
            appName: info.name,
            prompt: mediaSkillPrompt(baseUrl, apiKey,
                image: media.image, video: media.video),
          ),
          const SizedBox(height: 10),
        ],
        _DocsLink(appName: info.name, onOpen: onOpenSite),
      ],
    );
  }

  /// The chat-provider walkthrough: the app's setup steps and the exact config
  /// block to paste. Hermes has a one-click in-app flow, so its GUI steps lead
  /// and the config file drops to a "prefer editing files?" alternative; a
  /// file-based client leads with the block its steps reference.
  List<Widget> _chatSetup() {
    final guide = appSetupGuide(info);
    final fileFirst = info.app != ClientApp.hermes;
    return [
      _SetupSteps(title: guide.title, steps: guide.steps),
      const SizedBox(height: 16),
      if (fileFirst)
        GuideLabel(info.name, caption: 'Paste into ${info.configPath}')
      else
        GuideLabel('Prefer editing files?', caption: info.configPath),
      CodeBlock(code: _snippet()),
    ];
  }

  String _snippet() => switch (info.app) {
    ClientApp.openClaw => openClawSnippet(baseUrl, apiKey, model),
    ClientApp.hermes => hermesConfigSnippet(baseUrl, apiKey, model),
  };
}

/// Fallback for any app we don't detect: the same two copyable values plus a
/// tiny SDK example — enough to wire up anything by hand. For a media grid the
/// chat example gives way to a `curl` call against the image/video API.
class OtherAppPanel extends StatelessWidget {
  const OtherAppPanel({
    super.key,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.media,
    required this.hasChat,
  });

  final String baseUrl;
  final String apiKey;
  final String model;
  final GridMediaCapabilities media;
  final bool hasChat;

  @override
  Widget build(BuildContext context) {
    final showChat = hasChat || !media.any;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConnectionFields(baseUrl: baseUrl, apiKey: apiKey),
        const SizedBox(height: 16),
        if (showChat) ...[
          const GuideLabel(
            'Example (Python)',
            caption: 'works with any OpenAI SDK',
          ),
          CodeBlock(code: pythonSnippet(baseUrl, apiKey, model)),
          const SizedBox(height: 12),
          Text(
            'Use a model your grid serves (e.g. $model). Every model on every '
            'machine answers at this one endpoint.',
            style: const TextStyle(
              color: AppPalette.textFaint,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          if (media.any) const SizedBox(height: 16),
        ],
        if (media.any)
          _MediaApiCall(
            curl: mediaApiCurl(baseUrl, apiKey,
                image: media.image, video: media.video),
          ),
      ],
    );
  }
}

/// The media "build a skill" block for an agent client: paste this prompt and
/// the agent writes a reusable skill that calls the grid's image/video API. What
/// a media grid needs instead of a chat config, since it isn't a chat provider.
class _MediaSkillPrompt extends StatelessWidget {
  const _MediaSkillPrompt({required this.appName, required this.prompt});

  final String appName;
  final String prompt;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GuideLabel(
          'Have $appName build a skill',
          caption: "This grid makes images or video, not chat — so paste this "
              "into $appName and it'll create a reusable skill for it.",
        ),
        CodeBlock(code: prompt),
      ],
    );
  }
}

/// The media block for "Other app": a copy-run `curl` against the grid's
/// image/video API, for any tool that can make an HTTP request.
class _MediaApiCall extends StatelessWidget {
  const _MediaApiCall({required this.curl});

  final String curl;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GuideLabel(
          'Generate media',
          caption: 'Call the grid from any HTTP client (it streams SSE).',
        ),
        CodeBlock(code: curl),
      ],
    );
  }
}

/// The grid's OpenAI-compatible pair as two copyable fields — the two values any
/// client needs. The API Key is clamped to one line since it's an opaque string
/// the user copies, not reads.
class ConnectionFields extends StatelessWidget {
  const ConnectionFields({
    super.key,
    required this.baseUrl,
    required this.apiKey,
  });

  final String baseUrl;
  final String apiKey;

  @override
  Widget build(BuildContext context) {
    return DetailSection(
      title: 'Connection',
      children: [
        AddressRow(label: 'Base URL', value: baseUrl),
        AddressRow(label: 'API Key', value: apiKey, maxLines: 1),
      ],
    );
  }
}

/// The one-click setup card for an installed chat client: Grid writes the grid's
/// connection into the app's config so a non-technical user never edits YAML.
/// This is the fix for "No inference provider configured" — a backup is kept and
/// the manual config below stays as the fallback the error result points at.
class _ApplyBlock extends StatelessWidget {
  const _ApplyBlock({
    required this.name,
    required this.phase,
    required this.onApply,
  });

  final String name;
  final ApplyPhase phase;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final running = phase is ApplyRunning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Grid can write this connection into $name for you, so it uses this '
            'grid as its model — no files to edit (a backup is kept).',
            style: const TextStyle(
                color: AppPalette.textSecondary, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: running ? null : onApply,
            icon: running
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_rounded, size: 16),
            label: Text(running ? 'Setting up…' : 'Set up $name for me'),
          ),
          _ApplyStatus(phase: phase),
        ],
      ),
    );
  }
}

/// The result line after "Set up for me": success (green) with any follow-up
/// note, or a failure (red) telling the user to paste the config instead.
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
          text: '$message Copy the config below and paste it in yourself.',
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

/// Shown on a media-only grid: the agent needs its own chat model to run and
/// build the skill, and this grid (images/video) can't be that model. Names the
/// next step so the user isn't stuck on "No inference provider configured".
class _NeedsChatModelNote extends StatelessWidget {
  const _NeedsChatModelNote({required this.appName, required this.command});

  final String appName;
  final String command;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Text(
        '$appName needs its own chat model to run and build this skill. This '
        "grid only makes images or video, so it can't be that model — set one "
        'up first (run `$command model`, or add a provider API key in $appName), '
        'then paste the prompt below.',
        style: const TextStyle(
            color: AppPalette.textSecondary, fontSize: 12.5, height: 1.4),
      ),
    );
  }
}

/// A one-line note + Download button shown when the client isn't installed yet.
class _MissingAppNote extends StatelessWidget {
  const _MissingAppNote({required this.name, required this.onDownload});

  final String name;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "You don't have $name yet. Install it first, then paste the "
            'connection below.',
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.download_rounded, size: 16),
            label: Text('Download $name'),
          ),
        ],
      ),
    );
  }
}

/// A titled, numbered walkthrough to finish setup — the app's own [steps] in
/// plain language (see `appSetupGuide`).
class _SetupSteps extends StatelessWidget {
  const _SetupSteps({required this.title, required this.steps});

  final String title;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GuideLabel(title),
        const SizedBox(height: 2),
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${i + 1}.  ${steps[i]}',
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
      ],
    );
  }
}

/// A subtle link to the app's official site for deeper setup docs.
class _DocsLink extends StatelessWidget {
  const _DocsLink({required this.appName, required this.onOpen});

  final String appName;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$appName docs',
              style: const TextStyle(
                color: AppPalette.accent,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 3),
            const Icon(
              Icons.open_in_new_rounded,
              size: 13,
              color: AppPalette.accent,
            ),
          ],
        ),
      ),
    );
  }
}
