import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../../shared/widgets/toast.dart';
import '../../auto_router/presentation/auto_router_card.dart';
import '../../playground/presentation/playground_dialog.dart';
import '../logic/delete_network_controller.dart';
import '../logic/grid_overview_provider.dart';
import 'add_member_dialog.dart';
import 'consumer_env_card.dart';
import '../../../shared/widgets/detail_widgets.dart';
import 'grid_hardware_section.dart';
import 'grid_overview_card.dart';
import 'members_tab.dart';
import 'rename_grid_dialog.dart';

/// Right-hand detail pane for the selected network — Tailscale device-detail
/// style: a status header over the grid's content. Admins and providers get a
/// tabbed view (Overview / Members) so they can manage who's on the grid.
class NetworkDetail extends ConsumerWidget {
  const NetworkDetail({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
      child: _Header(network: network),
    );

    // Member management (the Members tab) is owner-only — the control plane
    // doesn't support member admin for providers yet. Everyone else, providers
    // included, gets just the overview.
    if (!network.canManageProvider) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(child: _OverviewTab(network: network)),
        ],
      );
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: Colors.transparent,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Members'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _OverviewTab(network: network),
                MembersTab(network: network),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The grid's overview content (stats, connection, role-specific cards, and
/// actions) — the default tab, also shown on its own for non-admins.
class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
      children: [
        // Headline stats stay pinned under the running status.
        const GridStatsSection(),
        // What the grid can actually do (Chat / Images / Video) — the only place
        // a media capability shows, since it isn't a listed model.
        const GridCapabilitiesSection(),
        // One primary action for everyone: use the grid once it serves a model,
        // otherwise set it up (owner/provider) or wait for one (consumer).
        const SizedBox(height: 18),
        _PrimaryAction(network: network),
        // The models it serves, and the nodes serving them. Each adds its own
        // leading gap and collapses to nothing when empty.
        const GridModelsSection(),
        // Auto-routing sits directly under the models it routes between — it is
        // a setting *about* them, and this is the grid's own page, which is the
        // scope every `router` command actually carries (`--grid <id>`, never a
        // node). It lived on "This computer" before, where it was the one
        // control that outlived the machine being switched off.
        //
        // Owner-only, gated here rather than inside the card: AutoRouterCard
        // leaves that to its caller (router commands are owner-level).
        if (network.isOwner) ...[
          const SizedBox(height: 18),
          const AutoRouterCard(),
        ],
        // The grid's pooled hardware at a glance — memory split by machine,
        // capacity, speed — read before the per-machine Nodes list below it.
        const GridHardwareSection(),
        const GridNodesSection(),
        // Raw developer credentials are a consumer convenience; owners/providers
        // manage via the Engines tab and reach the guide from "Use this grid",
        // so the API-access block is dropped from their overview.
        if (!network.canManageProvider) ...[
          const SizedBox(height: 24),
          ConsumerEnvCard(network: network),
        ],
        // Owner-only, pinned to the bottom: permanently delete this grid.
        if (network.isOwner) ...[
          const SizedBox(height: 28),
          _DeleteGridButton(network: network),
        ],
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // The grid's live operational state from its API: "running" when a node is
    // serving it, anything else (stopped, still loading, or unreachable) reads
    // as Stopped. One operational vocabulary — never the access-token state.
    final state = ref.watch(gridOverviewProvider).asData?.value.state;
    final running = state?.toLowerCase() == 'running';
    final label = running ? 'Running' : 'Stopped';
    final color = running ? AppPalette.online : AppPalette.offline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Title + badges take the remaining width (name ellipsizes) so the
            // header actions pin to the top-right, like page-level actions.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      network.name,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GridBadges(network: network),
                  // Renaming edits the grid's own title, so the pencil sits on
                  // the title rather than among the header actions.
                  if (network.isOwner) _RenameGridButton(network: network),
                ],
              ),
            ),
            // Owner/provider header action: managing members. Using the grid is
            // the body's "Use this grid" card (for every role), so the header
            // carries no test/try button.
            if (network.canManageProvider) ...[
              const SizedBox(width: 12),
              _AddMemberButton(network: network),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            StatusDot(color: color, size: 9),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ],
        ),
      ],
    );
  }
}

/// The empty-grid card for someone who can host on it: says plainly *why* the
/// grid can't do anything yet and what the next step is, instead of a lone
/// "Set up engine" button with no context. Mirrors [_TryThisGrid], so the first
/// screen always reads as one card with a headline, a reason and an action.
/// (The real "Start engine" lives in Engines once a model is ready — hence
/// "Set up", not "Start".)
class _SetUpThisGrid extends ConsumerWidget {
  const _SetUpThisGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Get this grid running',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Your grid is empty — no AI model is running on it yet. Set up an '
            'engine on this computer and pick a model, and the grid can answer '
            'questions here and in your other apps.',
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              // Both of these jump to a settings section, so both wear that
              // section's own glyph — taken from [ShellSection], not typed in
              // again here. "Set up engine" used to carry a DNS mark while the
              // screen it opens is a server: one action, two symbols, and
              // nothing linking the button to where it lands.
              FilledButton.icon(
                onPressed: () => ref
                    .read(shellSectionProvider.notifier)
                    .select(ShellSection.engines),
                icon: Icon(
                  ShellSection.engines.icon,
                  size: AppControl.iconSize,
                ),
                label: const Text('Set up engine'),
              ),
              OutlinedButton.icon(
                onPressed: () => ref
                    .read(shellSectionProvider.notifier)
                    .select(ShellSection.guide),
                icon: Icon(ShellSection.guide.icon, size: AppControl.iconSize),
                label: const Text('How it works'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The grid's front-door action — the plain answer to "what do I do here?".
/// Waits for the overview (the stats section owns the loading/error message),
/// then branches on whether the grid serves anything usable yet:
/// - serving a model → a prominent "Use this grid" for everyone;
/// - nothing yet + can host (owner/provider) → just "Set up engine";
/// - nothing yet + consumer → a human "come back later" note, never a dead end.
class _PrimaryAction extends ConsumerWidget {
  const _PrimaryAction({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(gridOverviewProvider);
    if (overview.isLoading || overview.hasError) {
      return const SizedBox.shrink();
    }
    final usable =
        ref.watch(gridHasChatProvider) ||
        ref.watch(gridMediaCapabilitiesProvider).any;
    if (usable) return const _TryThisGrid();
    return network.canManageProvider
        ? const _SetUpThisGrid()
        : const _NothingServedYet();
  }
}

/// Prominent "use this grid" card for a consumer — the two ways to actually use
/// it, side by side: **Try it** opens the quick in-app chat (the same dialog the
/// header "Test" opens for providers), and **How to use** jumps to the guide for
/// wiring the grid into their own apps. No jargon, no setup.
class _TryThisGrid extends ConsumerWidget {
  const _TryThisGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Use this grid',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Send it a message here, or connect it to your own apps.',
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: () => openPlaygroundDialog(context, ref),
                icon: const Icon(
                  Icons.chat_bubble_outline,
                  size: AppControl.iconSize,
                ),
                label: const Text('Try it'),
              ),
              // Jumps to the guide, so it wears the guide's own glyph — see the
              // note on [_SetUpThisGrid]'s pair above. ("Try it" opens a dialog
              // rather than a section, so its chat mark stays its own.)
              OutlinedButton.icon(
                onPressed: () => ref
                    .read(shellSectionProvider.notifier)
                    .select(ShellSection.guide),
                icon: Icon(ShellSection.guide.icon, size: AppControl.iconSize),
                label: const Text('How to use'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shown to a consumer when the grid is reachable but serving nothing yet, so an
/// idle public grid reads as "come back later" instead of looking broken.
class _NothingServedYet extends StatelessWidget {
  const _NothingServedYet();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: AppPalette.textFaint),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'No one is sharing a model on this grid right now. Check back '
              'later, or open another grid to try it.',
              style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Owner-only title action: opens the rename dialog. Icon-only (a pencil next
/// to the grid's name), so it carries a tooltip.
class _RenameGridButton extends ConsumerWidget {
  const _RenameGridButton({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: 'Rename grid',
      visualDensity: VisualDensity.compact,
      color: AppPalette.textFaint,
      icon: const Icon(Icons.edit_outlined, size: 16),
      onPressed: () => RenameGridDialog.show(context, ref, network),
    );
  }
}

/// Admin/provider header action: opens the invite-member dialog. Reachable from
/// any tab, not just Members.
class _AddMemberButton extends StatelessWidget {
  const _AddMemberButton({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => AddMemberDialog.show(context, network.networkId),
      icon: const Icon(Icons.person_add_alt_1, size: AppControl.iconSize),
      label: const Text('Add member'),
    );
  }
}

/// Owner-only destructive action at the bottom of the detail: permanently
/// deletes the grid via the control plane (after a confirm). On success the
/// synced list drops it and the selection falls back to another grid.
class _DeleteGridButton extends ConsumerWidget {
  const _DeleteGridButton({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deleting =
        ref.watch(deleteNetworkControllerProvider) is DeleteNetworkDeleting;
    final error = Theme.of(context).colorScheme.error;
    // Its own block at the foot of the pane, set off by a divider and kept at
    // the compact scale so it never competes with the grid's real content.
    //
    // But it is *named* for what it does. It used to be drawn in
    // [AppPalette.textFaint] on the theory that danger should only appear in the
    // confirm dialog — which measured at 3.3:1 (light), below the 4.5:1 a label
    // needs and squarely in the range this app uses for disabled text. So the
    // one irreversible action on the screen was the faintest thing on it, and
    // its own confirm dialog then answered in red: you learned what the button
    // was only after pressing it. Small and last is how you keep an action out
    // of the way; greying it out to the point of looking dead is not.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, color: AppPalette.divider),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: deleting ? null : () => _confirmAndDelete(context, ref),
          style: TextButton.styleFrom(
            foregroundColor: error,
            // The wash only appears under the pointer — at rest the button is
            // just its label, which is what keeps it quiet.
            overlayColor: error,
            minimumSize: const Size(0, AppControl.heightSmall),
            padding: AppControl.paddingSmallIcon,
          ),
          icon: deleting
              ? const AppSpinner(size: SpinnerSize.small)
              : const Icon(Icons.delete_outline, size: AppControl.iconSize),
          label: Text(deleting ? 'Deleting…' : 'Delete grid'),
        ),
      ],
    );
  }

  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('Delete this grid?'),
          content: Text(
            'This permanently deletes "${network.name}" and removes everyone '
            "on it. This can't be undone.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              // Ink, not accent — matching the other grid dialogs, where the
              // colour belongs to the one button that acts.
              style: TextButton.styleFrom(
                foregroundColor: AppPalette.textSecondary,
              ),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;

    final toast = ToastScope.of(context);
    final name = network.name;
    final error = await ref
        .read(deleteNetworkControllerProvider.notifier)
        .delete(network.networkId);
    toast?.show(
      error != null
          ? ToastSpec(message: error, severity: ToastSeverity.error)
          : ToastSpec(
              message: 'Deleted "$name".',
              severity: ToastSeverity.success,
            ),
    );
  }
}
