import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/detail_widgets.dart';
import '../../../auth/logic/session_controller.dart';
import '../../../network/logic/grid_choice.dart';

/// The grids this account already belongs to, as rows you press to pick one.
///
/// Picking is the whole interaction — no radio, no Continue. A second control
/// confirming a choice the user just made is a step that only exists to be
/// clicked, and this screen's job is to end as soon as the question is answered.
///
/// Scrolls inside a fixed height rather than growing the onboarding card: an
/// account can be on a dozen grids, and a card that runs off a small desktop
/// window is one the user can't finish (§4).
class GridPickList extends ConsumerWidget {
  const GridPickList({super.key});

  /// Roughly four rows, then it scrolls. Enough that a typical account sees its
  /// whole list without moving anything.
  static const double _maxHeight = 216;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final networks = ref.watch(sessionProvider).networks;

    // Through the gate, not straight at [SelectedNetwork]: answering the
    // question and opening the door are one act, and the door has to stay open
    // afterwards — the grid can go away again later without the app throwing
    // the user back out to this screen.
    void pick(NetworkCredential network) =>
        ref.read(gridChoiceGateProvider.notifier).choose(network);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: _maxHeight),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        shrinkWrap: true,
        itemCount: networks.length,
        itemBuilder: (context, index) {
          final network = networks[index];
          return _GridRow(network: network, onTap: () => pick(network));
        },
      ),
    );
  }
}

/// One grid to press: the bolt, its name, and what the user is on it — owner,
/// or a public grid they joined (see [GridBadge]).
class _GridRow extends StatelessWidget {
  const _GridRow({required this.network, required this.onTap});

  final NetworkCredential network;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        // The app's row answer: an instant hover tint, no ripple — matching
        // [ChoiceRow] directly above it.
        splashFactory: NoSplash.splashFactory,
        hoverColor: AppSurface.hoverFill,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 9, 9, 9),
          child: Row(
            children: [
              Icon(
                Icons.bolt,
                size: AppControl.iconSize,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  network.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: AppFont.medium,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GridBadge(network: network),
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: AppPalette.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
