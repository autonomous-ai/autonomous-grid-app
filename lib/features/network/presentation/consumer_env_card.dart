import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _copyEnvBlock(context),
            icon: const Icon(Icons.terminal_rounded, size: 15),
            label: const Text('Copy'),
          ),
        ),
      ],
    );
  }

  /// Copies the two `export …` lines verbatim — paste into a shell to use any
  /// OpenAI-compatible client against this grid's relay.
  void _copyEnvBlock(BuildContext context) {
    final env = 'export BASE_URL="${network.relayBaseUrl}"\n'
        'export API_KEY="${network.relayApiKey}"';
    Clipboard.setData(ClipboardData(text: env));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Copied'), duration: Duration(seconds: 1)),
    );
  }

  /// Explains how to point an OpenAI-compatible agent at this grid, with the
  /// grid's real BASE_URL / API_KEY pre-filled into copy-ready snippets.
  void _showAgentGuide(BuildContext context) {
    final envSnippet = 'export OPENAI_BASE_URL="${network.relayBaseUrl}"\n'
        'export OPENAI_API_KEY="${network.relayApiKey}"';
    final pySnippet = 'from openai import OpenAI\n'
        '\n'
        'client = OpenAI(\n'
        '    base_url="${network.relayBaseUrl}",\n'
        '    api_key="${network.relayApiKey}",\n'
        ')\n'
        '\n'
        'resp = client.chat.completions.create(\n'
        '    model="<model>",  # any model this grid serves (see Models tab)\n'
        '    messages=[{"role": "user", "content": "Hello"}],\n'
        ')\n'
        'print(resp.choices[0].message.content)';

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppPalette.panelBg,
        title: const Text('Configure an agent'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This grid exposes an OpenAI-compatible endpoint. Point any '
                  'agent or SDK (OpenAI SDK, LangChain, Cursor, …) at the '
                  'BASE_URL and API_KEY below — no other changes needed.',
                  style: TextStyle(
                      color: AppPalette.textSecondary, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 18),
                const _GuideLabel('1 · Set the environment variables'),
                _CodeBlock(code: envSnippet),
                const SizedBox(height: 18),
                const _GuideLabel('2 · Or pass them directly (Python)'),
                _CodeBlock(code: pySnippet),
                const SizedBox(height: 14),
                const Text(
                  'Pick any model your grid serves from the Models tab and use '
                  'its name as the "model" value.',
                  style: TextStyle(
                      color: AppPalette.textFaint, fontSize: 12, height: 1.4),
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

/// A small heading above a code block in the agent guide.
class _GuideLabel extends StatelessWidget {
  const _GuideLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 12.5,
            fontWeight: FontWeight.w600),
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
