import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../shared/widgets/error_box.dart';
import '../logic/member_providers.dart';

/// Modal to invite a member to a managed grid via the control-plane API.
/// Open with [AddMemberDialog.show]; it refreshes the members list itself.
class AddMemberDialog extends ConsumerStatefulWidget {
  const AddMemberDialog({super.key, required this.networkId});

  final String networkId;

  static Future<void> show(BuildContext context, String networkId) {
    return showDialog<void>(
      context: context,
      builder: (_) => AddMemberDialog(networkId: networkId),
    );
  }

  @override
  ConsumerState<AddMemberDialog> createState() => _AddMemberDialogState();
}

class _AddMemberDialogState extends ConsumerState<AddMemberDialog> {
  final _email = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (!_looksLikeEmail(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final error = await ref.read(addMemberActionProvider)(
      networkId: widget.networkId,
      email: email,
      roles: [ManagedMemberRole.both.wire],
    );

    if (!mounted) return;
    if (error != null) {
      setState(() {
        _submitting = false;
        _error = error;
      });
      return;
    }

    ref.invalidate(networkMembersProvider(widget.networkId));
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Invited $email.'),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add member'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _email,
              autofocus: true,
              enabled: !_submitting,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'teammate@example.com',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              ErrorBox(message: _error!, maxHeight: 120),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}

/// A light client-side sanity check — the server is the real validator, this
/// just spares an obvious round-trip.
bool _looksLikeEmail(String value) {
  final at = value.indexOf('@');
  return at > 0 && at < value.length - 1 && !value.contains(' ');
}
