import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_segmented.dart';
import '../../network/presentation/grid_overview_widgets.dart';

/// How new chats are drawn: as messages, or as the assistant's own
/// command-line program.
///
/// One control for every assistant, here on Appearance, because the question
/// is about how the *person* wants to read a chat rather than about any one
/// agent — it used to sit on each agent's card and asked the same thing three
/// times. Hermes has no program to open and always shows messages; the
/// subtitle says so rather than greying anything out, since the choice still
/// applies to the other two.
class ChatSurfaceSection extends ConsumerWidget {
  const ChatSurfaceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final current = ref.watch(chatPrefsProvider.select((p) => p.chatSurface));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          title: 'How new chats look',
          // Says *when* it applies, on the heading itself. A chat keeps the
          // shape it started in, so someone who switches this and reopens
          // yesterday's chat would otherwise read the unchanged chat as the
          // setting not working.
          subtitle:
              'Applies to the next chat you start, with any assistant. Ones '
              'already open keep the shape they began in. Hermes always shows '
              'messages — it has no command-line app to open.',
        ),
        const SizedBox(height: 12),
        AppSegmented(
          segments: [
            for (final surface in AgentChatSurface.values)
              SegmentSpec(label: chatSurfaceLabel(surface)),
          ],
          selected: AgentChatSurface.values.indexOf(current),
          onChanged: (index) => ref
              .read(chatPrefsProvider.notifier)
              .setChatSurface(AgentChatSurface.values[index]),
        ),
        const SizedBox(height: 8),
        Text(
          chatSurfaceDetail(current),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppPalette.textSecondary),
        ),
      ],
    );
  }
}

/// The control's name for each surface.
String chatSurfaceLabel(AgentChatSurface surface) => switch (surface) {
  AgentChatSurface.list => 'Messages',
  AgentChatSurface.terminal => 'Terminal',
};

/// What picking it actually changes, in one line under the control.
///
/// Both surfaces stop and ask before the assistant runs a command or changes a
/// file — they differ in **who does the asking**, not in whether anyone does.
/// The list asks with the app's own card; the terminal asks in the CLI's words
/// and takes the answer from the keyboard. Copy must not imply the quieter
/// option is the looser one: it isn't, and a user who believed that would pick
/// the wrong one for the wrong reason.
String chatSurfaceDetail(AgentChatSurface surface) => switch (surface) {
  AgentChatSurface.list =>
    'One bubble per turn with the steps listed under it. It asks here, on a '
        'card, before it runs a command or changes a file.',
  AgentChatSurface.terminal =>
    "The assistant's own command-line app, live. It asks in its own words and "
        'you answer with the keyboard; typing mid-answer reaches the turn that '
        'is running.',
};
