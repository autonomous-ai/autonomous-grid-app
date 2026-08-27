import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/app_dialog.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/anchored_menu_position.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/extension_toolbar.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/skill_files.dart';
import '../../logic/skill_import.dart';
import '../../logic/skills_controller.dart';
import 'new_skill_dialog.dart';
import 'public_skill_dialog.dart';
import 'skill_target_picker.dart';
import 'skill_menu.dart';

/// The screen's one create action, now that there are three ways to get a
/// skill: write one here, bring a folder that already is one, or take one from
/// the catalog the app ships with.
///
/// A menu rather than three buttons in the toolbar — writing one is the common
/// case and the other two are occasional, and a toolbar that grows a button per
/// variation stops reading as a toolbar.
class AddSkillButton extends StatelessWidget {
  const AddSkillButton({super.key});

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: skillMenuStyle(),
      menuChildren: [
        Builder(
          builder: (menuContext) => SizedBox(
            width: kSkillMenuWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SkillMenuItem(
                  icon: Icons.edit_outlined,
                  label: 'Write a skill',
                  onPressed: () {
                    MenuController.maybeOf(menuContext)?.close();
                    showNewSkillDialog(context);
                  },
                ),
                SkillMenuItem(
                  icon: Icons.drive_folder_upload_outlined,
                  label: 'Upload a skill',
                  onPressed: () {
                    MenuController.maybeOf(menuContext)?.close();
                    showUploadSkillDialog(context);
                  },
                ),
                SkillMenuItem(
                  icon: Icons.storefront_outlined,
                  label: 'Public skills',
                  onPressed: () {
                    MenuController.maybeOf(menuContext)?.close();
                    showPublicSkillDialog(context);
                  },
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => ExtensionCreateButton(
        label: 'Add skill',
        onPressed: () {
          if (controller.isOpen) {
            controller.close();
            return;
          }
          controller.open(
            position: anchoredMenuPosition(
              context,
              menuSize: skillMenuSize(3),
              margin: 8,
              gap: 6,
              // The button sits at the toolbar's trailing edge, so a menu
              // growing rightwards from it would hang off the pane.
              alignEnd: true,
            ),
          );
        },
      ),
    );
  }
}

/// Brings in a skill somebody else wrote: pick (or drop) its folder, and if it
/// really is a skill, it's copied into the store as one of yours.
///
/// Copied rather than linked, and into the user's own folder: a skill that
/// lived outside the store would vanish from the assistant the day that folder
/// moved, and a folder the user went and found is their own — `public/` is for
/// what Grid hands them.
Future<void> showUploadSkillDialog(BuildContext context) => showAppDialog<void>(
  context: context,
  builder: (_) => const _UploadDialog(),
);

class _UploadDialog extends ConsumerStatefulWidget {
  const _UploadDialog();

  @override
  ConsumerState<_UploadDialog> createState() => _UploadDialogState();
}

class _UploadDialogState extends ConsumerState<_UploadDialog> {
  bool _dragging = false;
  bool _busy = false;

  /// Why the last attempt was refused, shown under the drop area rather than as
  /// a toast — the user is still in the dialog, about to try another folder,
  /// and the reason has to stay on screen while they do.
  String? _refusal;

  Future<void> _choose() async {
    final path = await getDirectoryPath(confirmButtonText: 'Use folder');
    if (path == null) return;
    await _take(path);
  }

  Future<void> _dropped(List<XFile> files) async {
    if (files.isEmpty) return;
    final path = files.first.path;
    // A dropped *file* is the common near-miss: a bare SKILL.md, which is the
    // card without the folder it belongs to.
    if (!Directory(path).existsSync()) {
      setState(
        () => _refusal =
            'Drop the skill\'s folder, not a file inside it — a skill is the '
            'whole folder.',
      );
      return;
    }
    await _take(path);
  }

  Future<void> _take(String path) async {
    // Checked here as well as in the writer, so the reason names the folder the
    // user just picked instead of arriving as a generic failure.
    final refusal = skillFolderRefusal(path);
    if (refusal != null) {
      setState(() => _refusal = refusal);
      return;
    }
    setState(() {
      _busy = true;
      _refusal = null;
    });
    final failure = await ref.read(skillsProvider.notifier).importFolder(path);
    if (!mounted) return;
    setState(() => _busy = false);
    if (failure != null) {
      setState(() => _refusal = failure);
      return;
    }
    Navigator.of(context).pop();
    ToastScope.show(
      context,
      ToastSpec(
        message: '${path.split('/').last} added — the assistant can use it.',
        severity: ToastSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 24, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 16, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 20),
      title: Row(
        children: [
          Expanded(
            child: Text(
              'Upload skill',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          AppIconButton(
            tooltip: 'Close',
            icon: Icons.close_rounded,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DropArea(
              dragging: _dragging,
              busy: _busy,
              onTap: _busy ? null : _choose,
              onDragging: (on) => setState(() => _dragging = on),
              onDropped: _dropped,
            ),
            if (_refusal != null) ...[
              const SizedBox(height: 14),
              Text(
                _refusal!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 18),
            const SkillTargetPicker(),
            const SizedBox(height: 18),
            Text(
              'File requirements',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppPalette.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            const _Requirement(
              'The folder must contain a $kSkillCardFileName.',
            ),
            const _Requirement(
              'That $kSkillCardFileName must open with a YAML card giving the '
              'skill\'s name and description.',
            ),
            const _Requirement(
              'Everything else in the folder — scripts, assets — comes along '
              'with it.',
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _busy ? null : _choose,
          child: Text(_busy ? 'Adding…' : 'Choose folder'),
        ),
      ],
    );
  }
}

class _DropArea extends StatelessWidget {
  const _DropArea({
    required this.dragging,
    required this.busy,
    required this.onTap,
    required this.onDragging,
    required this.onDropped,
  });

  final bool dragging;
  final bool busy;
  final VoidCallback? onTap;
  final ValueChanged<bool> onDragging;
  final ValueChanged<List<XFile>> onDropped;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return DropTarget(
      onDragEntered: (_) => onDragging(true),
      onDragExited: (_) => onDragging(false),
      onDragDone: (details) {
        onDragging(false);
        onDropped(details.files);
      },
      child: MouseRegion(
        cursor: busy ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            height: 132,
            decoration: BoxDecoration(
              color: dragging ? AppCard.tint10 : AppSurface.recess,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: busy
                  ? const AppSpinner()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.create_new_folder_outlined,
                          size: 26,
                          color: dragging
                              ? AppPalette.accent
                              : AppPalette.textFaint,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          dragging
                              ? 'Drop the folder'
                              : 'Drag and drop a skill folder, or click to '
                                    'choose one',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppPalette.textSecondary,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Requirement extends StatelessWidget {
  const _Requirement(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppPalette.textFaint, height: 1.45);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ', style: style),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
