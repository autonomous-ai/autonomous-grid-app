import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../projects/logic/project.dart';
import '../../projects/presentation/create_project_dialog.dart';
import '../../scheduled/logic/scheduled_jobs_controller.dart';
import '../logic/command_item.dart';

part 'command_palette_row.dart';

/// The one place to find anything: a chat, a project, a scheduled task, or the
/// screen you want — without knowing where the app keeps it.
///
/// Opened with ⌘K (Ctrl+K elsewhere) or the search button in the rail. Typing
/// searches everything you own; ↑/↓ move, ⏎ opens, ⌘1…⌘9 jump straight to a row,
/// Esc closes.
Future<void> showCommandPalette(BuildContext context) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x33000000),
  builder: (_) => const CommandPalette(),
);

class CommandPalette extends ConsumerStatefulWidget {
  const CommandPalette({super.key});

  @override
  ConsumerState<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<CommandPalette> {
  final _query = TextEditingController();

  /// Which row ⏎ would open. Reset whenever the results change under it, so the
  /// highlight never points at a row that scrolled out from under the user.
  int _highlight = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _highlight = (_highlight + delta) % count);
  }

  /// Close first, then act: a command may open its own dialog (Add a project),
  /// which must land on the navigator that outlives this palette rather than be
  /// popped along with it. Every command reads its providers synchronously, so
  /// `ref` is still valid across the pop.
  void _run(CommandItem item) {
    final navigator = Navigator.of(context);
    navigator.pop();
    runCommand(navigator.context, ref, item);
  }

  @override
  Widget build(BuildContext context) {
    final groups = searchCommands(
      query: _query.text,
      // Live only — archiving a chat takes it out of search too, which is most
      // of the point of filing it away.
      chats: ref.watch(chatSessionsProvider).live,
      projects: ref.watch(projectsProvider),
      tasks: ref.watch(scheduledJobsProvider).value ?? const [],
    );
    final items = flattenCommands(groups);
    final highlight = items.isEmpty ? 0 : _highlight.clamp(0, items.length - 1);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _move(1, items.length),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _move(-1, items.length),
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (items.isNotEmpty) _run(items[highlight]);
        },
        // The number beside a row is the number that opens it.
        for (final (index, key) in _digitKeys.indexed)
          SingleActivator(key, meta: true): () {
            if (index < items.length) _run(items[index]);
          },
      },
      child: Dialog(
        alignment: Alignment.topCenter,
        insetPadding: const EdgeInsets.only(top: 110, left: 24, right: 24),
        elevation: 20,
        backgroundColor: AppPalette.cardBg,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _QueryField(
                controller: _query,
                onChanged: (_) => setState(() => _highlight = 0),
              ),
              const Divider(height: 1),
              Flexible(
                child: items.isEmpty
                    ? const _NoMatch()
                    : _Results(
                        groups: groups,
                        highlight: highlight,
                        indexOf: items.indexOf,
                        onRun: _run,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Perform [item]. Everything it needs is read straight away, so a command that
/// opens a picker still works after the palette has closed.
void runCommand(BuildContext context, WidgetRef ref, CommandItem item) {
  final shell = ref.read(shellSectionProvider.notifier);
  switch (item) {
    case OpenChatCommand(:final chat):
      ref.read(chatSessionsProvider.notifier).select(chat.id);
      shell.select(ShellSection.chat);
    case NewChatCommand(:final project):
      ref.read(chatSessionsProvider.notifier).newChat(projectId: project?.id);
      shell.select(ShellSection.chat);
    case OpenTaskCommand(:final job):
      ref.read(selectedJobIdProvider.notifier).select(job.id);
      shell.select(ShellSection.scheduled);
    case AddProjectCommand():
      showCreateProjectDialog(context);
    case OpenSettingsCommand():
      shell.select(kDefaultSettingsSection);
    case GoToCommand(:final section):
      shell.select(section);
  }
}

/// ⌘1…⌘9 — nine is where a list stops being something you can count at a glance.
const List<LogicalKeyboardKey> _digitKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

class _QueryField extends StatelessWidget {
  const _QueryField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autofocus: true,
      style: const TextStyle(fontSize: 15),
      decoration: const InputDecoration(
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        hintText: 'Search chats, projects and tasks — or run a command',
        contentPadding: EdgeInsets.fromLTRB(18, 18, 18, 16),
      ),
    );
  }
}

/// The grouped results, each row numbered while it's still countable.
class _Results extends StatelessWidget {
  const _Results({
    required this.groups,
    required this.highlight,
    required this.indexOf,
    required this.onRun,
  });

  final List<CommandGroup> groups;
  final int highlight;
  final int Function(CommandItem) indexOf;
  final ValueChanged<CommandItem> onRun;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      shrinkWrap: true,
      children: [
        for (final group in groups) ...[
          _GroupLabel(label: group.label),
          for (final item in group.items)
            CommandRow(
              item: item,
              index: indexOf(item),
              selected: indexOf(item) == highlight,
              onTap: () => onRun(item),
            ),
        ],
      ],
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Text(
        label,
        style: TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11.5,
          fontWeight: AppFont.medium,
        ),
      ),
    );
  }
}

class _NoMatch extends StatelessWidget {
  const _NoMatch();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 34),
      child: Text(
        'Nothing matches that.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppPalette.textFaint),
      ),
    );
  }
}
