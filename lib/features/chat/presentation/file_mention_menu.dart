import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../projects/logic/agent_workspace.dart';

/// The longest shortlist the `@` menu shows before it asks the user to keep
/// typing. Comfortably more than the 280px box can hold at once, so scrolling
/// still reaches past what's visible.
const int _maxMatches = 60;

/// The `@` menu that floats above the composer: the files in the chat's folder,
/// filtered by what's typed after the `@`.
///
/// Picking one hands its name back through [onPick] so the composer drops it into
/// the message — the agent, whose working directory is this same folder, then
/// reads it by name. Presentational only; the folder listing is
/// [workdirEntriesProvider].
class FileMentionMenu extends ConsumerWidget {
  const FileMentionMenu({
    super.key,
    required this.workdir,
    required this.query,
    required this.onPick,
  });

  final String workdir;

  /// The text after the leading `@`; empty lists the whole folder.
  final String query;

  /// Called with the picked entry's name, ready to drop into the composer.
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Lives in a detached overlay above the composer — follow theme flips itself.
    AppTheme.watch(context);
    final entries = ref.watch(
      workdirEntriesProvider((path: workdir, hidden: false)),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppSurface.composerShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: switch (entries) {
        AsyncData(:final value) => _Results(
          matches: _match(value, query),
          hasAny: value.isNotEmpty,
          onPick: onPick,
        ),
        AsyncError() => const _Message('Could not read this folder.'),
        _ => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: AppSpinner(size: SpinnerSize.large)),
        ),
      },
    );
  }

  List<WorkspaceEntry> _match(List<WorkspaceEntry> all, String query) {
    final needle = query.trim().toLowerCase();
    final matches = needle.isEmpty
        ? all
        : [
            for (final entry in all)
              if (entry.name.toLowerCase().contains(needle)) entry,
          ];
    // The menu is a shortlist you keep typing to narrow, not a file browser
    // (that's the header's), and it scrolls in a 280px box — so past a couple of
    // screenfuls the rows are only there to be laid out. The list shrink-wraps
    // to size itself, which means every match is measured on every keystroke; a
    // folder of a few hundred files made each one cost.
    return matches.length > _maxMatches
        ? matches.sublist(0, _maxMatches)
        : matches;
  }
}

class _Results extends StatelessWidget {
  const _Results({
    required this.matches,
    required this.hasAny,
    required this.onPick,
  });

  final List<WorkspaceEntry> matches;
  final bool hasAny;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    if (matches.isEmpty) {
      return _Message(
        hasAny
            ? 'No file matches that.'
            : 'This chat\'s folder is empty. Open the chat in a project, or '
                  'drag a file in.',
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: matches.length,
        itemBuilder: (context, i) =>
            _FileRow(entry: matches[i], onTap: () => onPick(matches[i].name)),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.entry, required this.onTap});

  final WorkspaceEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Overlay-menu content — no top-down rebuild reaches it, so watch the theme.
    AppTheme.watch(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              Icon(
                entry.isDirectory
                    ? Icons.folder_outlined
                    : Icons.description_outlined,
                size: 17,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
              if (!entry.isDirectory)
                Text(
                  workspaceSizeLabel(entry),
                  style: TextStyle(fontSize: 11.5, color: AppPalette.textFaint),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    // Overlay-menu content — no top-down rebuild reaches it, so watch the theme.
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
      ),
    );
  }
}
