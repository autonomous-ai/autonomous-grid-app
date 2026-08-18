import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/no_grid_notice.dart';
import '../../../auth/logic/session_controller.dart';
import '../../../chat/presentation/chat_view.dart';
import 'office_doc_bar.dart';

/// The conversation beside the document — **that document's** conversation.
///
/// Not a second inbox: it is one of the app's ordinary chats, listed in the same
/// sidebar as every other, and clicking its row there brings the document back
/// with it. What is particular to Docs is only the pairing — one chat per file,
/// made when the file's first message goes out (see `officeDocChatProvider`).
///
/// So there is no "New chat" here. A new conversation in Docs is a new
/// *document*: the way to one is the rail's Docs row, or Open / New blank
/// beside the page. A button that started a loose chat on this screen would
/// leave the file on the right paired with nothing.
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

/// The column's head — just its name.
///
/// Same height and hairline as [OfficeDocBar] across the seam, so the two bars
/// read as one strip over the whole screen rather than two rules at different
/// heights.
class _Head extends StatelessWidget {
  const _Head();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: OfficeDocBar.height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Chat',
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 13.5,
                fontWeight: AppFont.medium,
              ),
            ),
          ),
        ),
      ),
      const Divider(height: 1, thickness: 1),
    ],
  );
}
