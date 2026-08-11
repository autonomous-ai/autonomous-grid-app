import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/glass_card.dart';
import '../logic/app_guide_snippets.dart';
import '../logic/client_app_configurator.dart';
import '../logic/client_app_detector.dart';
import '../logic/grid_overview_provider.dart';
import '../../../shared/widgets/detail_widgets.dart';
import 'missing_app_note.dart';
import 'setup_steps.dart';

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
/// the app's model, so instead of the chat setup + Apply it shows one compact
/// "build a skill" card per media capability (and a note that the agent needs
/// its own chat model first) — see [media] / [hasChat] and [_mediaSkillCards].
/// A grid that serves both keeps the chat setup/Apply and appends the media
/// cards.
class ClientAppPanel extends StatelessWidget {
  const ClientAppPanel({
    super.key,
    required this.info,
    required this.installed,
    required this.runsHere,
    required this.baseUrl,
    required this.apiKey,
    required this.models,
    required this.media,
    required this.hasChat,
    required this.phase,
    required this.onApply,
    required this.onOpenSite,
  });

  final ClientAppInfo info;
  final bool installed;

  /// Whether this grid serves a model that speaks the app's API at all — see
  /// [clientRunsOnGrid]. False replaces the setup with the reason, since the
  /// steps would end in a connection error.
  final bool runsHere;
  final String baseUrl;
  final String apiKey;

  /// Every chat model the grid serves (never empty — the caller falls back to a
  /// default). OpenClaw's config lists them all; Hermes and the copy that name a
  /// single model use the first.
  final List<String> models;

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
    AppTheme.watch(context);
    // Show chat setup for a chat grid, or while the overview still loads (media
    // resolves to none first) — so a chat grid never flashes without its steps.
    final showChat = hasChat || !media.any;
    // Only worth saying the grid can't answer this app once the grid has a model
    // at all: a brand-new grid reports every dialect false because nothing is
    // shared on it yet, and "no model here speaks its API" would blame the app
    // for an empty grid.
    final unsupported = !runsHere && hasChat;
    // One-click config write shows wherever the manual chat setup does — a chat
    // grid, or an as-yet-unknown one (overview/models still loading or the relay
    // unreachable, so `hasChat` reads false transiently). Only a positively
    // media-only grid hides it. Mirrors `showChat` so the button and the manual
    // steps never disagree, and the app must actually be installed to write into.
    // A grid that can't answer this app hides it too: the button promises the
    // grid becomes the app's model, which would be a promise it can't keep.
    final canApply = installed && showChat && !unsupported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!installed) ...[
          MissingAppNote(name: info.name, onDownload: onOpenSite),
          const SizedBox(height: 16),
        ],
        if (unsupported) ...[
          UnsupportedOnGridNote(name: info.name),
          const SizedBox(height: 16),
        ],
        // The URL this app wants, not the relay's raw one — see [appBaseUrl].
        ConnectionFields(
          baseUrl: appBaseUrl(info.app, baseUrl),
          apiKey: apiKey,
        ),
        const SizedBox(height: 16),
        if (canApply) ...[
          _ApplyBlock(name: info.name, phase: phase, onApply: onApply),
          const SizedBox(height: 16),
        ],
        // Skill cards sit right under the one-tap setup block — both are quick
        // "do it for me / copy" actions, so they group above the manual chat
        // steps below.
        if (media.any) ...[
          // A media-only grid can't be the app's chat model, so the agent still
          // needs its own model before it can build the skill — say so plainly.
          if (!hasChat) ...[
            NeedsChatModelNote(appName: info.name, command: info.executable),
            const SizedBox(height: 12),
          ],
          ..._mediaSkillCards(),
        ],
        if (showChat) ...[..._chatSetup(), const SizedBox(height: 16)],
        DocsLink(appName: info.name, onOpen: onOpenSite),
      ],
    );
  }

  /// The chat-provider walkthrough: the app's setup steps, then the exact
  /// block(s) to paste — one per file the app needs (Codex takes two: its config
  /// and the dotenv holding the key). Each block's label comes from
  /// [appSnippets], so Hermes's file stays a "prefer editing files?" alternative
  /// to its in-app flow while a file-based client leads with the block its steps
  /// reference.
  List<Widget> _chatSetup() {
    final guide = appSetupGuide(info);
    return [
      SetupSteps(title: guide.title, steps: guide.steps),
      const SizedBox(height: 16),
      for (final (i, block) in appSnippets(
        info,
        baseUrl,
        apiKey,
        models,
      ).indexed) ...[
        if (i > 0) const SizedBox(height: 12),
        GuideLabel(block.label, caption: block.caption),
        CodeBlock(code: block.code),
      ],
    ];
  }

  /// One compact skill card per media capability the grid serves, so image and
  /// video stay separate single-purpose skills (a grid that does both shows
  /// both). Each card copies the full paste-ready prompt for that one API.
  List<Widget> _mediaSkillCards() => [
    if (media.image) ...[
      _MediaSkillCard(
        icon: Icons.image_outlined,
        title: 'Have ${info.name} build an image skill',
        note:
            'Paste this into ${info.name} — it writes a reusable skill that '
            'makes images with this grid.',
        prompt: mediaSkillPrompt(baseUrl, apiKey, image: true, video: false),
      ),
      const SizedBox(height: 12),
    ],
    if (media.video) ...[
      _MediaSkillCard(
        icon: Icons.videocam_outlined,
        title: 'Have ${info.name} build a video skill',
        note:
            'Paste this into ${info.name} — it writes a reusable skill that '
            'turns an image into a short video with this grid.',
        prompt: mediaSkillPrompt(baseUrl, apiKey, image: false, video: true),
      ),
      const SizedBox(height: 12),
    ],
  ];
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
    AppTheme.watch(context);
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
            style: TextStyle(
              color: AppPalette.textFaint,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          if (media.any) const SizedBox(height: 16),
        ],
        if (media.any)
          _MediaApiCall(
            curl: mediaApiCurl(
              baseUrl,
              apiKey,
              image: media.image,
              video: media.video,
            ),
          ),
      ],
    );
  }
}

/// A compact "build a skill" card for one media capability (image or video) on
/// an agent client. A media grid isn't a chat provider — it's an HTTP API — so
/// instead of a config block we hand the agent a paste-ready prompt that writes
/// a reusable skill around it. The prompt is long and meant to be pasted, not
/// read, so the card shows just a one-line [title] and a short [note] with a
/// Copy button that puts the whole [prompt] on the clipboard.
class _MediaSkillCard extends StatelessWidget {
  const _MediaSkillCard({
    required this.icon,
    required this.title,
    required this.note,
    required this.prompt,
  });

  final IconData icon;
  final String title;
  final String note;
  final String prompt;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // An accent mark on a surface, not a fill — accentOnSurface.
              // Flat accent measures 3.22:1 on the dark inset; this is 5.75:1.
              Icon(icon, size: 16, color: AppPalette.accentOnSurface),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    fontWeight: AppFont.medium,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CopyButton(value: prompt),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, right: 8, top: 2),
            child: Text(
              note,
              style: TextStyle(
                color: AppPalette.textFaint,
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
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
    AppTheme.watch(context);
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
    AppTheme.watch(context);
    final running = phase is ApplyRunning;
    return GlassCard(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Grid can write this connection into $name for you, so it uses this '
            'grid as its model — no files to edit (a backup is kept).',
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: running ? null : onApply,
            icon: running
                ? const AppSpinner.onAccent()
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
  const _StatusLine({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
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
