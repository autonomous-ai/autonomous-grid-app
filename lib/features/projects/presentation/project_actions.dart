import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/widgets/toast.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../logic/project.dart';

/// Open [project]'s folder in the system file browser, telling the user if it
/// wouldn't open — a folder that's been moved or deleted.
///
/// Shared by the Projects list row and the project rail so a folder opens the
/// same way, and fails the same honest way, from either place.
Future<void> openProjectFolder(
  BuildContext context,
  WidgetRef ref,
  Project project,
) async {
  final opened = await ref
      .read(hostShellServiceProvider)
      .openFolder(project.path);
  if (!context.mounted || opened) return;
  ToastScope.show(
    context,
    ToastSpec(
      message: "Couldn't open ${project.path}",
      severity: ToastSeverity.error,
    ),
  );
}

/// Start a fresh chat inside [project] and jump to it, so the assistant answers
/// with that folder open and its standing brief in hand.
void startProjectChat(WidgetRef ref, Project project) {
  ref.read(chatSessionsProvider.notifier).newChat(projectId: project.id);
  ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
}
