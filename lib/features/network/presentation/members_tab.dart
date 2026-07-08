import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../logic/member_providers.dart';

/// The "Members" tab of a managed grid's detail pane — shown to admins and
/// providers. Lists active members and lets them invite or remove people via
/// the control-plane API.
class MembersTab extends ConsumerStatefulWidget {
  const MembersTab({super.key, required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends ConsumerState<MembersTab> {
  /// Emails with an in-flight DELETE, so each row shows its own spinner.
  final Set<String> _removing = {};

  String get _networkId => widget.network.networkId;

  Future<void> _confirmRemove(ManagedNetworkMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove member'),
        content: Text('Remove ${member.email} from this grid?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _remove(member.email);
  }

  Future<void> _remove(String email) async {
    setState(() => _removing.add(email));
    final error = await ref.read(removeMemberActionProvider)(
      networkId: _networkId,
      email: email,
    );
    if (!mounted) return;
    setState(() => _removing.remove(email));

    final messenger = ScaffoldMessenger.of(context);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    ref.invalidate(networkMembersProvider(_networkId));
    messenger.showSnackBar(
      SnackBar(
        content: Text('Removed $email.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(networkMembersProvider(_networkId));
    final count = membersAsync.asData?.value.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      children: [
        _Header(
          count: count,
          onRefresh: () => ref.invalidate(networkMembersProvider(_networkId)),
        ),
        const SizedBox(height: 16),
        membersAsync.when(
          loading: () => const _Message(
            icon: Icons.cloud_sync_outlined,
            text: 'Loading members…',
          ),
          error: (err, _) =>
              _Message(icon: Icons.cloud_off_outlined, text: '$err'),
          data: (members) => members.isEmpty
              ? const _Message(
                  icon: Icons.group_outlined,
                  text: 'No members yet. Invite someone to get started.',
                )
              : Column(
                  children: [
                    for (final m in members) ...[
                      _MemberTile(
                        member: m,
                        isOwner: m.isOwner,
                        removing: _removing.contains(m.email),
                        onRemove: () => _confirmRemove(m),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.count, required this.onRefresh});

  final int? count;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    // "Add member" now lives in the detail header beside Test — this row just
    // shows the count and a refresh.
    return Row(
      children: [
        Text(
          count == null ? 'Members' : 'Members ($count)',
          style: const TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.refresh, size: 18),
          color: AppPalette.textSecondary,
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.isOwner,
    required this.removing,
    required this.onRemove,
  });

  final ManagedNetworkMember member;
  final bool isOwner;
  final bool removing;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      blurred: false,
      sheen: false,
      borderRadius: BorderRadius.circular(10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 18,
            backgroundColor: AppPalette.cardBgHover,
            child: Icon(
              Icons.person_outline,
              size: 18,
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              member.email,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // The owner is a permanent member — show a badge, never a remove button.
          if (isOwner)
            const _OwnerBadge()
          else if (removing)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              color: AppPalette.textSecondary,
              tooltip: 'Remove member',
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// Pill marking the grid owner among the members.
class _OwnerBadge extends StatelessWidget {
  const _OwnerBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppPalette.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppPalette.accent.withValues(alpha: 0.45)),
      ),
      child: const Text(
        'Owner',
        style: TextStyle(
          color: AppPalette.accent,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppPalette.textFaint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
