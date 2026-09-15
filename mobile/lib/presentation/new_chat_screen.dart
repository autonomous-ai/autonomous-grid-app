/// Starting a conversation from the phone.
///
/// Created with its first message rather than as an empty room: a chat with
/// nothing in it is not written to the computer's disk, so an empty one made
/// here would be a chat the same computer then says it does not have.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_chat_options.dart';
import '../logic/phone_chats.dart';
import '../logic/relay_phone_client.dart';
import 'chat_screen.dart';
import 'grid_app_bar.dart';

/// Asks what to say, and where.
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({this.projectId, super.key});

  /// Start it in this project. Null asks.
  final String? projectId;

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _text = TextEditingController();
  String? _projectId;
  bool _starting = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _projectId = widget.projectId;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_text.text.trim().isEmpty || _starting) return;
    setState(() {
      _starting = true;
      _problem = null;
    });
    try {
      final id = await startChat(ref, text: _text.text, projectId: _projectId);
      if (!mounted) return;
      // Replaces rather than pushes: going Back from a chat that was just
      // started should land on the list it now appears in, not on the empty
      // form that made it.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(id: id, title: _text.text.trim()),
        ),
      );
    } on RelayPhoneFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _problem = failure.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final projects = ref.watch(projectsProvider).value ?? const {};
    final radius = BorderRadius.circular(AppCard.radius);
    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      appBar: const GridAppBar(title: 'New chat'),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (projects.isNotEmpty) ...[
                Text(
                  'Project',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: AppPalette.textFaint,
                  ),
                ),
                const SizedBox(height: 8),
                _ProjectChoice(
                  projects: projects.values.toList(),
                  selected: _projectId,
                  onPick: (id) => setState(() => _projectId = id),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _text,
                autofocus: true,
                minLines: 3,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  hintText: 'What do you want to ask?',
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: AppPalette.textFaint,
                  ),
                  filled: true,
                  fillColor: AppPalette.cardBg,
                  contentPadding: const EdgeInsets.all(14),
                  border: OutlineInputBorder(
                    borderRadius: radius,
                    borderSide: BorderSide(color: AppGlass.hair),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: radius,
                    borderSide: BorderSide(color: AppGlass.hair),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: radius,
                    borderSide: BorderSide(color: AppPalette.accentOnSurface),
                  ),
                ),
              ),
              if (_problem case final problem?) ...[
                const SizedBox(height: 12),
                Text(
                  problem,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.dangerFill,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
                onPressed: _starting ? null : _start,
                child: Text(_starting ? 'Starting…' : 'Start chat'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which project the new chat belongs to, or none.
class _ProjectChoice extends StatelessWidget {
  const _ProjectChoice({
    required this.projects,
    required this.selected,
    required this.onPick,
  });

  final List<ProjectRow> projects;
  final String? selected;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Choice(
          label: 'No project',
          selected: selected == null,
          onPick: () => onPick(null),
        ),
        for (final project in projects)
          _Choice(
            label: project.name.isEmpty ? project.id : project.name,
            selected: selected == project.id,
            onPick: () => onPick(project.id),
          ),
      ],
    );
  }
}

/// One project, as a pill — the same 34/11 pill the composer uses, so the two
/// places a person picks something look like the same control.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onPick,
  });

  final String label;
  final bool selected;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return InkWell(
      borderRadius: BorderRadius.circular(11),
      onTap: onPick,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppPalette.accent : AppGlass.surfaceFill,
          border: Border.all(
            color: selected ? AppPalette.accent : AppGlass.hair,
          ),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected ? Colors.white : AppPalette.textSecondary,
          ),
        ),
      ),
    );
  }
}
