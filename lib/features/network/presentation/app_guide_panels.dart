import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/app_guide_snippets.dart';
import '../logic/client_app_detector.dart';
import 'detail_widgets.dart';

/// Read-only setup for one known client: the grid's Base URL + Token as copyable
/// fields, the exact config block to paste, short steps, and a Download prompt
/// when the app is missing. Grid never writes the user's config — they paste it
/// themselves, so nothing on disk is touched and the copy stays honest.
class ClientAppPanel extends StatelessWidget {
  const ClientAppPanel({
    super.key,
    required this.info,
    required this.installed,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.onOpenSite,
  });

  final ClientAppInfo info;
  final bool installed;
  final String baseUrl;
  final String apiKey;

  /// The model the grid actually serves (or the fallback default), wired into
  /// the snippet so it names a model the grid can answer.
  final String model;

  /// Opens the app's official site — the Download target when missing, and the
  /// "docs" affordance otherwise.
  final VoidCallback onOpenSite;

  @override
  Widget build(BuildContext context) {
    final guide = appSetupGuide(info);
    // Hermes has a one-click in-app flow, so its GUI steps lead and the config
    // file drops to a "prefer editing files?" alternative. A file-based client
    // leads with the block it pastes (its steps reference "the block below").
    final fileFirst = info.app != ClientApp.hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!installed) ...[
          _MissingAppNote(name: info.name, onDownload: onOpenSite),
          const SizedBox(height: 16),
        ],
        ConnectionFields(baseUrl: baseUrl, apiKey: apiKey),
        const SizedBox(height: 16),
        _SetupSteps(title: guide.title, steps: guide.steps),
        const SizedBox(height: 16),
        if (fileFirst)
          GuideLabel(info.name, caption: 'Paste into ${info.configPath}')
        else
          GuideLabel('Prefer editing files?', caption: info.configPath),
        CodeBlock(code: _snippet()),
        const SizedBox(height: 10),
        _DocsLink(appName: info.name, onOpen: onOpenSite),
      ],
    );
  }

  String _snippet() => switch (info.app) {
        ClientApp.openClaw => openClawSnippet(baseUrl, apiKey, model),
        ClientApp.hermes => hermesConfigSnippet(baseUrl, apiKey, model),
      };
}

/// Fallback for any app we don't detect: the same two copyable values plus a
/// tiny SDK example — enough to wire up anything by hand.
class OtherAppPanel extends StatelessWidget {
  const OtherAppPanel({
    super.key,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConnectionFields(baseUrl: baseUrl, apiKey: apiKey),
        const SizedBox(height: 16),
        const GuideLabel('Example (Python)',
            caption: 'works with any OpenAI SDK'),
        CodeBlock(code: pythonSnippet(baseUrl, apiKey, model)),
        const SizedBox(height: 12),
        Text(
          'Use a model your grid serves (e.g. $model). Every model on every '
          'machine answers at this one endpoint.',
          style: const TextStyle(
              color: AppPalette.textFaint, fontSize: 12, height: 1.45),
        ),
      ],
    );
  }
}

/// The grid's OpenAI-compatible pair as two copyable fields — the two values any
/// client needs. The Token is clamped to one line since it's an opaque string
/// the user copies, not reads.
class ConnectionFields extends StatelessWidget {
  const ConnectionFields(
      {super.key, required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  @override
  Widget build(BuildContext context) {
    return DetailSection(
      title: 'Connection',
      children: [
        AddressRow(label: 'Base URL', value: baseUrl),
        AddressRow(label: 'Token', value: apiKey, maxLines: 1),
      ],
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
                color: AppPalette.textSecondary, fontSize: 12.5, height: 1.4),
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
                  color: AppPalette.textSecondary, fontSize: 12.5, height: 1.4),
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
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.open_in_new_rounded,
                size: 13, color: AppPalette.accent),
          ],
        ),
      ),
    );
  }
}
