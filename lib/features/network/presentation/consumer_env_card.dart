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
/// `grid consumer env` prints (OPENAI_BASE_URL + OPENAI_API_KEY). Both are
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
    final env = 'export OPENAI_BASE_URL="${network.relayBaseUrl}"\n'
        'export OPENAI_API_KEY="${network.relayApiKey}"';
    Clipboard.setData(ClipboardData(text: env));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Copied'), duration: Duration(seconds: 1)),
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
