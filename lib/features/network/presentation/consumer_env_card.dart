import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import 'detail_widgets.dart';

/// The set of grids whose API key is currently revealed. Kept in a provider
/// (not local widget state) so the choice survives rebuilds, but scoped by
/// networkId so revealing one grid's key never uncovers another's.
final _revealedKeysProvider =
    NotifierProvider<_RevealedKeysNotifier, Set<String>>(
        _RevealedKeysNotifier.new);

class _RevealedKeysNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String networkId) {
    final next = {...state};
    if (!next.add(networkId)) next.remove(networkId); // add() false ⇒ was present
    state = next;
  }
}

/// The consumer's OpenAI-compatible credentials for a grid — the exact pair
/// `grid info --env` prints (OPENAI_BASE_URL + OPENAI_API_KEY). Both are
/// derived from the already-loaded credential ([NetworkCredential.relayBaseUrl]
/// / [NetworkCredential.relayApiKey]), so this needs no subprocess. The key is
/// masked until the viewer reveals it.
class ConsumerEnvCard extends ConsumerWidget {
  const ConsumerEnvCard({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final revealed =
        ref.watch(_revealedKeysProvider).contains(network.networkId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailSection(
          title: 'API access (for developers)',
          trailing: IconButton(
            icon: const Icon(Icons.help_outline_rounded, size: 16),
            color: AppPalette.textSecondary,
            tooltip: 'How to configure an agent',
            visualDensity: VisualDensity.compact,
            onPressed: () => _showAgentGuide(context),
          ),
          children: [
            EnvVarRow(name: 'OPENAI_BASE_URL', value: network.relayBaseUrl),
            EnvVarRow(
              name: 'OPENAI_API_KEY',
              value: network.relayApiKey,
              secret: true,
              revealed: revealed,
              onToggleReveal: () => ref
                  .read(_revealedKeysProvider.notifier)
                  .toggle(network.networkId),
            ),
          ],
        ),
        // const SizedBox(height: 8),
        // Align(
        //   alignment: Alignment.centerLeft,
        //   child: TextButton.icon(
        //     onPressed: () => _copyEnvBlock(context),
        //     icon: const Icon(Icons.terminal_rounded, size: 15),
        //     label: const Text('Copy'),
        //   ),
        // ),
      ],
    );
  }

  /// Explains how to point any OpenAI-compatible app at this grid. Mirrors the
  /// README's "Point your apps at the grid" — the same `OPENAI_*` pair (as
  /// `grid info --env` prints) wired into OpenClaw, Hermes and a plain SDK, with
  /// this grid's real BASE_URL / API_KEY pre-filled into copy-ready snippets.
  void _showAgentGuide(BuildContext context) {
    final base = network.relayBaseUrl;
    final key = network.relayApiKey;

    final envSnippet = 'export OPENAI_BASE_URL="$base"\n'
        'export OPENAI_API_KEY="$key"';

    final openClawSnippet = '{\n'
        '  "agents": { "defaults": { "model": { "primary": "grid/qwen3-coder" } } },\n'
        '  "models": {\n'
        '    "providers": {\n'
        '      "grid": {\n'
        '        "baseUrl": "$base",\n'
        '        "apiKey": "$key",\n'
        '        "api": "openai-completions",\n'
        '        "models": [{ "id": "qwen3-coder", "name": "Qwen3 Coder (via Grid)" }]\n'
        '      }\n'
        '    }\n'
        '  }\n'
        '}';

    final hermesSnippet = 'model:\n'
        '  provider: custom\n'
        '  default: qwen3-coder\n'
        '  base_url: $base';
    final hermesEnvSnippet = "echo 'OPENAI_API_KEY=$key' >> ~/.hermes/.env";

    final pySnippet = 'from openai import OpenAI\n'
        '\n'
        'client = OpenAI(base_url="$base", api_key="$key")\n'
        'client.chat.completions.create(\n'
        '    model="qwen3-coder",                # routed to a matching engine automatically\n'
        '    messages=[{"role": "user", "content": "hello"}],\n'
        ')';

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppPalette.panelBg,
        title: const Text('Point your apps at the grid'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This grid is one OpenAI-compatible endpoint. Wire these two '
                  'values — OPENAI_BASE_URL and OPENAI_API_KEY (the same pair '
                  '`grid info --env` prints) — into any OpenAI-compatible client.',
                  style: TextStyle(
                      color: AppPalette.textSecondary, fontSize: 13, height: 1.45),
                ),
                const SizedBox(height: 18),
                const _GuideLabel('Environment variables'),
                _CodeBlock(code: envSnippet),
                const SizedBox(height: 18),
                const _GuideLabel('OpenClaw',
                    caption: 'add Grid as a provider in ~/.openclaw/openclaw.json'),
                _CodeBlock(code: openClawSnippet),
                const SizedBox(height: 18),
                const _GuideLabel('Hermes',
                    caption: 'set the endpoint in ~/.hermes/config.yaml'),
                _CodeBlock(code: hermesSnippet),
                const SizedBox(height: 8),
                _CodeBlock(code: hermesEnvSnippet),
                const SizedBox(height: 18),
                const _GuideLabel('Your own app',
                    caption: 'point any OpenAI SDK at the values above'),
                _CodeBlock(code: pySnippet),
                const SizedBox(height: 14),
                const Text(
                  'Replace qwen3-coder with a model your grid serves. Every model '
                  'on every machine answers at this one endpoint.',
                  style: TextStyle(
                      color: AppPalette.textFaint, fontSize: 12, height: 1.45),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// A heading above a code block in the agent guide, with an optional caption
/// (e.g. the config file the snippet belongs in).
class _GuideLabel extends StatelessWidget {
  const _GuideLabel(this.text, {this.caption});
  final String text;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: const TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600),
          ),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                caption!,
                style: const TextStyle(
                    color: AppPalette.textFaint, fontSize: 11.5, height: 1.3),
              ),
            ),
        ],
      ),
    );
  }
}

/// A monospace, selectable code panel with a copy button in the corner.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 40, 12),
            child: SelectableText(
              code,
              style: const TextStyle(
                  color: AppPalette.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.45),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: CopyIconButton(value: code),
          ),
        ],
      ),
    );
  }
}

/// A monospace `NAME` → value row for an environment variable. Secrets are
/// masked until [revealed]; the copy button always copies the real value.
class EnvVarRow extends StatelessWidget {
  const EnvVarRow({
    super.key,
    required this.name,
    required this.value,
    this.secret = false,
    this.revealed = false,
    this.onToggleReveal,
  });

  final String name;
  final String value;
  final bool secret;
  final bool revealed;
  final VoidCallback? onToggleReveal;

  @override
  Widget build(BuildContext context) {
    final shown = secret && !revealed ? _mask(value) : value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shown,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppPalette.textPrimary,
                      fontFamily: 'monospace',
                      fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(name,
                    style: const TextStyle(
                        color: AppPalette.textSecondary, fontSize: 11.5)),
              ],
            ),
          ),
          if (secret)
            IconButton(
              icon: Icon(
                  revealed
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 15),
              color: AppPalette.textSecondary,
              tooltip: revealed ? 'Hide' : 'Reveal',
              visualDensity: VisualDensity.compact,
              onPressed: onToggleReveal,
            ),
          CopyIconButton(value: value),
        ],
      ),
    );
  }

  /// Show the first/last 4 chars so the viewer can sanity-check which key it is
  /// without exposing it (e.g. `eyJh••••••••••••0kQ2`).
  static String _mask(String v) => v.length <= 8
      ? '••••••••'
      : '${v.substring(0, 4)}${'•' * 12}${v.substring(v.length - 4)}';
}
