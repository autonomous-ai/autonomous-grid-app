/// Starting a conversation from the phone.
///
/// Created with its first message rather than as an empty room: a chat with
/// nothing in it is not written to the computer's disk, so an empty one made
/// here would be a chat the same computer then says it does not have.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/phone_chat_options.dart';
import '../logic/phone_chats.dart';
import '../logic/relay_phone_client.dart';
import 'chat_screen.dart';

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
    final theme = Theme.of(context);
    final projects = ref.watch(projectsProvider).value ?? const {};
    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (projects.isNotEmpty) ...[
                Text('Project', style: theme.textTheme.bodySmall),
                const SizedBox(height: 6),
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
                decoration: const InputDecoration(
                  hintText: 'What do you want to ask?',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_problem case final problem?) ...[
                const SizedBox(height: 12),
                Text(
                  problem,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
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
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      ChoiceChip(
        label: const Text('No project'),
        selected: selected == null,
        onSelected: (_) => onPick(null),
      ),
      for (final project in projects)
        ChoiceChip(
          label: Text(project.name.isEmpty ? project.id : project.name),
          selected: selected == project.id,
          onSelected: (_) => onPick(project.id),
        ),
    ],
  );
}
