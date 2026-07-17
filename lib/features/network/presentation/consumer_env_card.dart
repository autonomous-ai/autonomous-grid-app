import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import 'detail_widgets.dart';

/// The set of grids whose API key is currently revealed. Kept in a provider
/// (not local widget state) so the choice survives rebuilds, but scoped by
/// networkId so revealing one grid's key never uncovers another's.
final _revealedKeysProvider =
    NotifierProvider<_RevealedKeysNotifier, Set<String>>(
      _RevealedKeysNotifier.new,
    );

class _RevealedKeysNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String networkId) {
    final next = {...state};
    // add() false ⇒ it was already there, so this is an un-reveal.
    if (!next.add(networkId)) next.remove(networkId);
    state = next;
  }
}

/// The consumer's OpenAI-compatible credentials for a grid — the exact pair
/// `grid info --env` prints (OPENAI_BASE_URL + OPENAI_API_KEY). Both are
/// derived from the already-loaded credential ([NetworkCredential.relayBaseUrl]
/// / [NetworkCredential.relayApiKey]), so this needs no subprocess. The key is
/// masked until the viewer reveals it, and "How to use" jumps to the full How to
/// use section that wires these values into a real client for them.
class ConsumerEnvCard extends ConsumerStatefulWidget {
  const ConsumerEnvCard({super.key, required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<ConsumerEnvCard> createState() => _ConsumerEnvCardState();
}

class _ConsumerEnvCardState extends ConsumerState<ConsumerEnvCard> {
  // Collapsed by default so developer credentials never dominate the first
  // thing a non-technical user sees — the "How to use" shortcut stays visible
  // in the header regardless, and a developer expands the raw values once.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final network = widget.network;
    final revealed = ref
        .watch(_revealedKeysProvider)
        .contains(network.networkId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _EnvHeader(
          expanded: _expanded,
          onToggle: () => setState(() => _expanded = !_expanded),
          // Consumers reach "How to use" from the prominent "Use this grid"
          // card, so only owners/providers (who have no such card) need the
          // shortcut here — avoids showing it twice on the consumer overview.
          showHowToUse: network.canManageProvider,
        ),
        if (_expanded) ...[
          const SizedBox(height: 8),
          GlassCard(
            child: Column(
              children: [
                EnvVarRow(name: 'OPENAI_BASE_URL', value: network.relayBaseUrl),
                const Divider(height: 1, indent: 14, endIndent: 14),
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
          ),
        ],
      ],
    );
  }
}

/// The collapsible header for [ConsumerEnvCard]: a chevron + section label that
/// toggles the raw credentials, with the "How to use" shortcut pinned at the
/// trailing edge so it's reachable without expanding anything.
class _EnvHeader extends StatelessWidget {
  const _EnvHeader({
    required this.expanded,
    required this.onToggle,
    required this.showHowToUse,
  });

  final bool expanded;
  final VoidCallback onToggle;

  /// Whether to show the "How to use" shortcut at the trailing edge. Off for
  /// consumers, who already have it on the "Use this grid" card above.
  final bool showHowToUse;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.chevron_right_rounded,
                    size: 18,
                    color: AppPalette.textFaint,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'API ACCESS (FOR DEVELOPERS)',
                    style: TextStyle(
                      color: AppPalette.textFaint,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showHowToUse) const _HowToUseButton(),
      ],
    );
  }
}

/// Jumps to the full "How to use" guide — the plain-language path that wires
/// this grid's credentials into a real client for a non-technical user.
class _HowToUseButton extends ConsumerWidget {
  const _HowToUseButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Tooltip(
      message: 'See how to connect your apps to this grid',
      child: TextButton.icon(
        icon: const Icon(Icons.help_outline_rounded, size: AppControl.iconSize),
        label: const Text('How to use'),
        // Sits inline in the section header row, so it stays on the compact
        // scale; the muted label keeps it quieter than the heading beside it.
        style: TextButton.styleFrom(
          foregroundColor: AppPalette.textSecondary,
          minimumSize: const Size(0, AppControl.heightSmall),
          padding: AppControl.paddingSmall,
        ),
        onPressed: () =>
            ref.read(shellSectionProvider.notifier).select(ShellSection.guide),
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
                  // A credential the user copies into their own env — mono via
                  // the token, so `l`/`1` and `0`/`O` stay apart. See [AppFont].
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontFamily: AppFont.mono,
                    fontFamilyFallback: AppFont.monoFallback,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  name,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          if (secret)
            IconButton(
              icon: Icon(
                revealed
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 15,
              ),
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
