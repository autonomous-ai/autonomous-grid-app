import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/onboarding_page.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/choice_row.dart';
import '../../../shared/widgets/error_box.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_choice.dart';
import '../../network/logic/grid_sync_controller.dart';
import 'widgets/grid_pick_list.dart';
import 'widgets/new_grid_form.dart';

/// The first thing after signing in: which grid is this?
///
/// The app used to answer it silently — [CredentialsFile.active] picks a grid
/// out of a five-deep fallback — so a user on more than one grid landed
/// somewhere they hadn't chosen and had no reason to look for the switch. Every
/// screen behind this one reads the answer (what model the grid serves, where
/// chat sends, what this computer would share), so it is worth one screen.
///
/// Asked once. [gridChoiceNeededProvider] is false the moment a grid is picked,
/// and the answer is remembered across launches — a returning user goes straight
/// to chat, and changes their mind in Settings ▸ Grid.
class GridChoiceScreen extends ConsumerStatefulWidget {
  const GridChoiceScreen({super.key});

  @override
  ConsumerState<GridChoiceScreen> createState() => _GridChoiceScreenState();
}

/// Which row is showing its own form. Only one at a time — the screen is a fork,
/// and two open forms would make it look like both had to be filled in.
enum _OpenRow { existing, create }

class _GridChoiceScreenState extends ConsumerState<GridChoiceScreen> {
  _OpenRow? _open;

  @override
  Widget build(BuildContext context) {
    final networks = ref.watch(sessionProvider).networks;
    final hasGrids = networks.isNotEmpty;
    // An account with no grids has only one honest answer, so the create form
    // opens itself rather than making the user press a row whose alternative
    // isn't there. Otherwise the list leads: picking is one click from here.
    final open = _open ?? (hasGrids ? _OpenRow.existing : _OpenRow.create);

    void toggle(_OpenRow row) =>
        setState(() => _open = open == row ? null : row);

    return OnboardingPage(
      title: 'Choose your grid',
      // Says what a grid *is* before asking which one — this is the first time
      // the word carries any weight for a new user — and that the answer isn't
      // final, which is what lets the rest of the screen stay this short. The
      // two rows below already say "pick one, or make one", so the line doesn't
      // repeat them.
      subtitle:
          'A grid is the private network your AI runs on. You can switch '
          'grids later in Settings.',
      children: [
        ChoiceRowGroup(
          outlined: true,
          children: [
            if (hasGrids)
              ChoiceRow(
                icon: const Icon(Icons.bolt),
                title: 'Your grids',
                line: _countLine(networks.length),
                action: ChoiceRowAction.open,
                expanded: open == _OpenRow.existing,
                onPressed: () => toggle(_OpenRow.existing),
                child: open == _OpenRow.existing ? const GridPickList() : null,
              ),
            ChoiceRow(
              icon: const Icon(Icons.add_circle_outline),
              title: 'New grid',
              line: 'Start your own — you choose who can join.',
              action: ChoiceRowAction.open,
              expanded: open == _OpenRow.create,
              onPressed: () => toggle(_OpenRow.create),
              child: open == _OpenRow.create ? const NewGridForm() : null,
            ),
          ],
        ),
        const SizedBox(height: 14),
        _RefreshRow(hasGrids: hasGrids),
        const SizedBox(height: 4),
        const _SkipRow(),
      ],
    );
  }
}

/// How many grids are behind the row, in words a person would use.
String _countLine(int count) =>
    count == 1 ? '1 grid on your account' : '$count grids on your account';

/// The way out of "my grid isn't here": pull the list again from the account.
///
/// It earns its place because the list this screen shows is whatever the last
/// `grid sync` wrote — a grid someone shared with you five minutes ago is on
/// your account and not yet on this computer, and without this the screen would
/// be a dead end for exactly the user who was invited to a grid.
class _RefreshRow extends ConsumerWidget {
  const _RefreshRow({required this.hasGrids});

  /// Changes only the question, not the button: with no grids at all the line
  /// has to explain why the list is empty rather than assume one is missing.
  final bool hasGrids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final sync = ref.watch(gridSyncControllerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sync is GridSyncFailed) ...[
          ErrorBox(message: sync.message),
          const SizedBox(height: 10),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                hasGrids
                    ? 'Don’t see your grid?'
                    : 'Invited to a grid by someone else?',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (sync is GridSyncRunning)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: AppSpinner(size: SpinnerSize.small),
              )
            else
              TextButton(
                onPressed: () =>
                    ref.read(gridSyncControllerProvider.notifier).sync(),
                child: const Text('Refresh'),
              ),
          ],
        ),
      ],
    );
  }
}

/// The way past the question, for a user who can't answer it right now — the
/// control plane is down, or the person who invited them hasn't yet.
///
/// Quiet, not accent: it is the way out, not one of the answers (the same
/// reasoning as the model fork's "I'll set this up later"). It says "later"
/// rather than "skip" because [gridChoiceGateProvider] only holds for this
/// run — the app will ask again, and a button promising otherwise would lie.
class _SkipRow extends ConsumerWidget {
  const _SkipRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: TextButton(
        onPressed: () => ref.read(gridChoiceGateProvider.notifier).later(),
        // Ink, not the faint token: a control has to clear 4.5:1 on this white
        // card, which `textFaint` doesn't (§11).
        style: TextButton.styleFrom(foregroundColor: AppPalette.textSecondary),
        child: const Text('I’ll choose later'),
      ),
    );
  }
}
