import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/analytics/analytics_events.dart';
import '../../../../infrastructure/analytics/analytics_providers.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/choice_row.dart';
import '../../../../shared/widgets/detail_widgets.dart';
import '../../../auth/logic/session_controller.dart';
import '../../../network/logic/grid_access_summary.dart';
import '../../../network/logic/grid_choice.dart';

/// The grids this account already belongs to, as rows you press to pick one.
///
/// Picking is the whole interaction — no radio, no Continue. A second control
/// confirming a choice the user just made is a step that only exists to be
/// clicked, and this screen's job is to end as soon as the question is answered.
///
/// It is the group itself now, not the contents of one. It used to live inside a
/// "Your grids · 1 grid on your account" row you had to open: a disclosure whose
/// entire payload, for most accounts, was a single line — and whose summary
/// *described* the list ("1 grid") in the space where the list would have fit.
/// A screen asking you to choose should open showing the things to choose from.
///
/// Scrolls inside a fixed height rather than growing the onboarding card: an
/// account can be on a dozen grids, and a card that runs off a small desktop
/// window is one the user can't finish (§4).
class GridPickList extends ConsumerWidget {
  const GridPickList({super.key, required this.remember});

  /// Whether picking a grid here also writes it down for the next launch.
  /// Read at the moment of the press, so the tick below the list applies to
  /// the choice the user is making right now.
  final bool remember;

  /// Roughly five rows, then it scrolls. The list grows with every public
  /// grid the account can reach, so it has to stay a list rather than become
  /// the page.
  static const double _maxHeight = 235;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final networks = ref.watch(sessionProvider).networks;

    // Through the gate, not straight at [SelectedNetwork]: answering the
    // question and opening the door are one act, and the door has to stay open
    // afterwards — the grid can go away again later without the app throwing
    // the user back out to this screen.
    void pick(NetworkCredential network) {
      ref.read(analyticsProvider).gridChoice('existing');
      ref
          .read(gridChoiceGateProvider.notifier)
          .choose(network, remember: remember);
    }

    return ChoiceRowGroup(
      outlined: true,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _maxHeight),
          child: ListView.separated(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: networks.length,
            separatorBuilder: (_, _) =>
                Divider(height: 1, thickness: 1, color: AppPalette.divider),
            itemBuilder: (context, index) {
              final network = networks[index];
              return _GridRow(network: network, onTap: () => pick(network));
            },
          ),
        ),
      ],
    );
  }
}

/// One grid to press: the bolt, its name, and the tag saying why you can enter
/// it.
///
/// One line, unlike the create-a-grid [ChoiceRow] below it, and the difference
/// is the point: these are *items* to scan — an account can reach many of them
/// — while that row is an action that has to explain itself. A list reads
/// fastest when each entry is one line and the only thing varying across them
/// sits in the same place on every row.
///
/// The tag carries what a sentence under the name would have, in a quarter of
/// the space and without a second vocabulary: a row saying "Anyone signed in to
/// Grid" beneath a pill saying "Public" is one fact printed twice.
class _GridRow extends StatelessWidget {
  const _GridRow({required this.network, required this.onTap});

  final NetworkCredential network;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final tag = gridAccessTagFor(network);
    return InkWell(
      onTap: onTap,
      // The app's row answer: an instant hover tint, no ripple — matching
      // [ChoiceRow], which this row shares a card with.
      splashFactory: NoSplash.splashFactory,
      hoverColor: AppSurface.hoverFill,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 13, 13, 13),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: Center(
                child: Icon(
                  Icons.bolt,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                network.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: 10),
            gridPill(tag.label, gridTagColour(tag)),
            const SizedBox(width: 10),
            Icon(
              Icons.chevron_right_rounded,
              size: 19,
              color: AppPalette.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// The tag's tint, kept in step with the grid badges everywhere else: Public is
/// the accent it already wears on the Grids screen, Owner the teal. Invited is
/// the quiet one on purpose — it is the ordinary case, and a list where every
/// row shouts has nothing left to point at the one that should be noticed.
Color gridTagColour(GridAccessTag tag) => switch (tag) {
  GridAccessTag.public => AppPalette.accent,
  GridAccessTag.owner => AppPalette.teal,
  GridAccessTag.invited => AppPalette.textSecondary,
};
