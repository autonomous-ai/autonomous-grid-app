import 'package:flutter/material.dart';

import '../../../shared/widgets/coming_soon_view.dart';

/// The Projects screen: a folder on this computer the assistant is allowed to
/// read, so you can ask it about the files in it instead of pasting them in.
///
/// Not built yet — this says so plainly rather than shipping controls that do
/// nothing. TODO(BE): the agent already runs in a fixed, app-owned workspace
/// (`agentWorkspaceDirProvider`); a project means pointing that workdir at a
/// folder the user chose, and deciding what it may read.
class ProjectsView extends StatelessWidget {
  const ProjectsView({super.key});

  @override
  Widget build(BuildContext context) {
    return const ComingSoonView(
      title: 'Projects',
      subtitle:
          'A folder on this computer the assistant can read, so it can answer '
          'about your own files.',
      icon: Icons.folder_open_rounded,
      points: [
        'Pick a folder — a codebase, a pile of notes, a set of documents.',
        'Ask about what\'s in it without pasting anything into the chat.',
        'Keep it read-only: the assistant looks, it does not change your files.',
      ],
    );
  }
}
