import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/toast.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/member_providers.dart';

/// The "People with access" block of [ShareGridDialog] — everyone already on
/// the grid, and the way off it.
///
/// Its own file rather than a section of the dialog: the dialog is three
/// unrelated jobs stacked (invite, list, access mode), and the list is the one
/// with its own async states and its own per-row menu.
class SharePeopleList extends ConsumerStatefulWidget {
  const SharePeopleList({super.key, required this.networkId});

  final String networkId;

  /// The tallest the list draws before it scrolls inside itself. A grid can
  /// hold hundreds of people; a dialog that grows with them runs off the
  /// screen, and the access control below would go with it.
  ///
  /// This is the one part of the dialog that scrolls — the sheet around it
  /// deliberately doesn't (see [ShareGridDialog]) — so on a short window it
  /// gives way first, down to [minHeight]. Two rows is enough to read as a
  /// list; below that it would be a scroll bar with nothing beside it.
  static const double maxHeight = 208;
  static const double minHeight = 88;

  /// [maxHeight], or a quarter of a short window — whichever is smaller.
  static double capFor(BuildContext context) {
    final quarter = MediaQuery.sizeOf(context).height * 0.25;
    return quarter.clamp(minHeight, maxHeight);
  }

  @override
  ConsumerState<SharePeopleList> createState() => _SharePeopleListState();
}

class _SharePeopleListState extends ConsumerState<SharePeopleList> {
  /// Emails with a DELETE in flight, so each row spins on its own rather than
  /// the whole list going blank.
  final Set<String> _removing = {};

  Future<void> _remove(ManagedNetworkMember member) async {
    setState(() => _removing.add(member.email));
    final error = await ref.read(removeMemberActionProvider)(
      networkId: widget.networkId,
      email: member.email,
    );
    if (!mounted) return;
    setState(() => _removing.remove(member.email));

    if (error != null) {
      ToastScope.show(
        context,
        ToastSpec(message: error, severity: ToastSeverity.error),
      );
      return;
    }
    ref.invalidate(networkMembersProvider(widget.networkId));
    ToastScope.show(
      context,
      ToastSpec(
        message: 'Removed ${member.email}.',
        severity: ToastSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final members = ref.watch(networkMembersProvider(widget.networkId));
    final me = ref.watch(sessionProvider).userEmail?.toLowerCase();

    return members.when(
      loading: () => const _PeopleSkeleton(),
      error: (err, _) => _Note(text: '$err'),
      data: (people) => people.isEmpty
          ? const _Note(text: 'Only you, for now.')
          : ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: SharePeopleList.capFor(context),
              ),
              // Shrink-wraps until it hits the cap, so three people don't sit
              // in a box sized for ten.
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: people.length,
                itemBuilder: (context, i) => _PersonRow(
                  member: people[i],
                  isYou: people[i].email.toLowerCase() == me,
                  removing: _removing.contains(people[i].email),
                  onRemove: () => _remove(people[i]),
                ),
              ),
            ),
    );
  }
}

/// One person: who they are on the left, what they may do on the right.
class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.member,
    required this.isYou,
    required this.removing,
    required this.onRemove,
  });

  final ManagedNetworkMember member;
  final bool isYou;
  final bool removing;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final email = member.email;
    final initial = email.trim().isEmpty ? '?' : email.trim()[0].toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          _Initial(initial: initial),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isYou ? '$email (you)' : email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    height: 1.25,
                    fontWeight: AppFont.medium,
                  ),
                ),
                if (member.status case final status?
                    when status.toLowerCase() != 'active') ...[
                  const SizedBox(height: 2),
                  Text(
                    status,
                    style: TextStyle(
                      color: AppPalette.textFaint,
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (removing)
            const Padding(padding: EdgeInsets.all(6), child: AppSpinner())
          // The owner is a permanent member — the control plane won't remove
          // them, so they get a word rather than a control that can't work.
          else if (member.isOwner)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                'Owner',
                style: TextStyle(color: AppPalette.textFaint, fontSize: 13),
              ),
            )
          // The one thing this row can actually do. It used to be a menu
          // shaped like Google's role picker, with the roles drawn dead
          // because there's no endpoint to change one — which meant four rows
          // of nothing wrapped around the single row that worked. A button
          // that does the one available thing beats a menu that mostly can't.
          //
          // TODO(BE): no `PATCH …/members/{email}` to change a member's role,
          // so this row can add and remove but never adjust. Restore the role
          // menu here once it exists — and do NOT stand in for it with
          // DELETE + POST: a failed POST drops the person off the grid.
          // `.claude/share-grid-plan.md` §2.3.
          //
          // `destructive` keeps the glyph neutral at rest and turns it red
          // only under the pointer: a column of red buttons sitting idle reads
          // as an error state rather than a list of people.
          else
            AppIconButton(
              icon: LucideIcons.trash2300,
              tooltip: 'Remove access',
              destructive: true,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// The circle carrying a person's first initial.
///
/// Deliberately not the gradient disc the sidebar's account pill wears: that
/// one marks *you*, and repeating it down a list of other people would say
/// everyone here is the signed-in user.
class _Initial extends StatelessWidget {
  const _Initial({required this.initial});
  final String initial;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppPalette.cardBgHover,
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: AppPalette.textSecondary,
          fontSize: 13,
          fontWeight: AppFont.medium,
        ),
      ),
    );
  }
}

/// The list before it arrives: rows in the shape they'll land in.
///
/// A sentence ("Loading people…") made the dialog jump — the line is one row
/// tall, so the access section below it leapt down the moment the members
/// arrived. Rows that already occupy the space don't, which is the whole point
/// of a skeleton over a spinner.
///
/// Three rows, not the [SkeletonList] default of five: this block is capped at
/// [SharePeopleList.capFor] anyway, and a skeleton taller than the list it
/// stands in for causes the jump it exists to prevent — upward, which is worse.
/// Padding and the single line match [_PersonRow] exactly, so nothing shifts
/// sideways either.
class _PeopleSkeleton extends StatelessWidget {
  const _PeopleSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Fading down the column so the block reads as "more below" rather than
        // as a wall that stops at an arbitrary row — the trick SkeletonList
        // uses, kept here because the row padding is this dialog's, not its.
        Opacity(opacity: 1, child: _PeopleSkeletonRow()),
        Opacity(opacity: 0.78, child: _PeopleSkeletonRow()),
        Opacity(opacity: 0.56, child: _PeopleSkeletonRow()),
      ],
    );
  }
}

/// One placeholder row, padded like the real one.
class _PeopleSkeletonRow extends StatelessWidget {
  const _PeopleSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const SkeletonListTile(
      // A person's row is one line — the email. The second line only appears
      // for a member the server flags as not active, which is the exception.
      subtitle: false,
      padding: EdgeInsets.symmetric(vertical: 6),
    );
  }
}

/// Empty and error read as one calm line rather than two differently-shaped
/// blocks — the list is a paragraph of the dialog, not a screen of its own.
class _Note extends StatelessWidget {
  const _Note({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
        style: TextStyle(
          color: AppPalette.textSecondary,
          fontSize: 13,
          height: 1.35,
        ),
      ),
    );
  }
}
