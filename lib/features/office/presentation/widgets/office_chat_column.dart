import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/no_grid_notice.dart';
import '../../../auth/logic/session_controller.dart';
import '../../../chat/logic/chat_sessions_controller.dart';
import '../../../chat/presentation/chat_view.dart';
import 'office_doc_bar.dart';

/// The conversation beside the document.
///
/// It is **the** open conversation, not a second one: the app has one active chat
/// and the sidebar lists them all, so what the user asks here is in the Chat
/// section when they walk over to it, and the reverse. A private chat per
/// document would give the same person two inboxes for one thought.
///
/// The transcript and composer are [ChatView] unchanged — the same model picker,
/// attachments, agent and history the Chat section uses. Nothing about the chat
/// is reimplemented for this screen; only the frame around it is new.
class OfficeChatColumn extends ConsumerWidget {
  const OfficeChatColumn({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final network = ref.watch(selectedNetworkProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Head(),
        Expanded(
          child: network == null
              ? const NoGridNotice(compact: true)
              : ChatView(network: network),
        ),
      ],
    );
  }
}

/// The column's head — its name, and the way to start over.
///
/// Same height and hairline as [OfficeDocBar] across the seam, so the two bars
/// read as one strip over the whole screen rather than two rules at different
/// heights.
class _Head extends ConsumerWidget {
  const _Head();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    children: [
      SizedBox(
        height: OfficeDocBar.height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Chat',
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13.5,
                    fontWeight: AppFont.medium,
                  ),
                ),
              ),
              AppIconButton(
                icon: LucideIcons.squarePen300,
                size: 16,
                tooltip: 'New chat',
                onPressed: () =>
                    ref.read(chatSessionsProvider.notifier).newChat(),
              ),
            ],
          ),
        ),
      ),
      const Divider(height: 1, thickness: 1),
    ],
  );
}
