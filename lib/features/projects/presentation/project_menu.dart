import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/project.dart';

/// The "…" overflow menu on a project row: pin it to the top, reveal its folder,
/// rename it, or take it off the list. Mirrors the app's MenuAnchor pattern so it
/// reads like every other menu (the task-power and account menus).
class ProjectMenuButton extends ConsumerStatefulWidget {
  const ProjectMenuButton({super.key, required this.project});

  final Project project;

  @override
  ConsumerState<ProjectMenuButton> createState() => _ProjectMenuButtonState();
}

class _ProjectMenuButtonState extends ConsumerState<ProjectMenuButton> {
  final _menu = MenuController();

  Project get _project => widget.project;

  void _togglePin() {
    _menu.close();
    ref
        .read(projectsProvider.notifier)
        .setPinned(_project.id, !_project.pinned);
  }

  Future<void> _reveal() async {
    _menu.close();
    final opened = await ref
        .read(hostShellServiceProvider)
        .openFolder(_project.path);
    if (opened || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text("Couldn't open ${_project.path}")));
  }

  Future<void> _rename() async {
    _menu.close();
    await showRenameProjectDialog(context, ref, _project);
  }

  Future<void> _remove() async {
    _menu.close();
    final ok = await confirmRemoveProject(context, _project);
    if (ok) ref.read(projectsProvider.notifier).remove(_project.id);
  }

  @override
  Widget build(BuildContext context) {
    final missing = !_project.exists;
    return MenuAnchor(
      controller: _menu,
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(
            _project.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            size: 17,
          ),
          onPressed: _togglePin,
          child: Text(_project.pinned ? 'Unpin project' : 'Pin project'),
        ),
        if (!missing)
          MenuItemButton(
            leadingIcon: const Icon(Icons.folder_open_outlined, size: 17),
            onPressed: _reveal,
            child: const Text('Show in Finder'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.drive_file_rename_outline, size: 17),
          onPressed: _rename,
          child: const Text('Rename project'),
        ),
        MenuItemButton(
          leadingIcon: Icon(
            Icons.delete_outline_rounded,
            size: 17,
            color: Theme.of(context).colorScheme.error,
          ),
          onPressed: _remove,
          child: Text(
            'Remove from Grid',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: 'Project options',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 24, height: 24),
        iconSize: 17,
        splashRadius: 14,
        color: AppPalette.textSecondary,
        icon: const Icon(Icons.more_horiz_rounded),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Renames [project] after asking for the new name. The folder on disk never
/// moves — only the label. Cancelling, or leaving it blank, changes nothing.
Future<void> showRenameProjectDialog(
  BuildContext context,
  WidgetRef ref,
  Project project,
) async {
  final controller = TextEditingController(text: project.name);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename project'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Rename'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name != null) {
    ref.read(projectsProvider.notifier).rename(project.id, name);
  }
}

/// Confirms taking [project] off the list. Returns true only when the user says
/// so — the folder and its files stay exactly where they are either way.
Future<bool> confirmRemoveProject(BuildContext context, Project project) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove "${project.name}"?'),
      content: const Text(
        'The folder and its files stay exactly where they are — this only '
        'takes it off your list, and its chats move out of the project.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
