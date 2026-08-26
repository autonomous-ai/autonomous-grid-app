import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/analytics/analytics_events.dart';
import '../../../../infrastructure/analytics/analytics_providers.dart';
import '../../../../infrastructure/api/models/managed_network.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../auth/logic/session_controller.dart';
import '../../../network/logic/create_network_controller.dart';
import '../../../network/logic/grid_access_types.dart';
import '../../../network/logic/grid_choice.dart';
import '../../../network/logic/grid_name.dart';
import '../../../network/presentation/grid_type_picker.dart';

/// Start a grid of your own, from the first-run screen: a name, who may join,
/// and one button.
///
/// The same controller the Grids screen's dialog uses, so a grid made on the way
/// in is made exactly the way a grid made later is — created on the control
/// plane, pulled local with `grid sync`, and pointed at with `grid use`. What
/// differs is only what happens after: the dialog closes and toasts, while this
/// selects the new grid, which is what ends this screen.
class NewGridForm extends ConsumerStatefulWidget {
  const NewGridForm({super.key});

  @override
  ConsumerState<NewGridForm> createState() => _NewGridFormState();
}

class _NewGridFormState extends ConsumerState<NewGridForm> {
  final _name = TextEditingController();
  ManagedNetworkType _type = ManagedNetworkType.fallback;

  /// The grid was created but couldn't be pulled onto this computer, so there
  /// is nothing to select yet. Kept apart from the controller's own failure:
  /// this one is a caveat on a success, and re-submitting would try to create a
  /// second grid of the same name.
  String? _warning;

  @override
  void initState() {
    super.initState();
    // Outside build (§2), and after the frame: the controller is app-wide, so a
    // create that finished on a previous visit would otherwise show this form
    // already "done".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(createNetworkControllerProvider.notifier).reset();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit(ManagedNetworkType type) {
    setState(() => _warning = null);
    ref
        .read(createNetworkControllerProvider.notifier)
        .submit(name: _name.text, type: type);
  }

  /// Take the freshly created grid as the user's choice — the whole point of
  /// making one here. It has to be looked up rather than used directly: the
  /// screen selects a [NetworkCredential] (tokens and all, written by
  /// `grid sync`), and the API hands back only the control-plane record.
  void _onCreated(CreateNetworkDone done) {
    final match = ref.read(sessionProvider).byName(done.network.networkId);
    if (match != null) {
      ref.read(analyticsProvider).gridChoice('new');
      ref.read(gridChoiceGateProvider.notifier).choose(match);
      return;
    }
    setState(() {
      _warning =
          done.joinWarning ??
          'Grid “${done.network.name}” was created, but it hasn’t reached '
              'this computer yet. Try Refresh below.';
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(createNetworkControllerProvider, (_, next) {
      if (next is CreateNetworkDone) _onCreated(next);
    });

    final state = ref.watch(createNetworkControllerProvider);
    final submitting = state is CreateNetworkSubmitting;
    final error = state is CreateNetworkFailed ? state.message : _warning;

    // The domain rule is only offered when the server says this account can use
    // it; while that answer is loading, or if it fails, the option is absent.
    final domain = ref.watch(gridDomainProvider).value;
    final types = accessTypesFor(canRestrictToDomain: domain != null);
    // A rule that stopped being offered must not stay selected — the picker
    // would show nothing chosen while `_type` still sent `domain-restricted`.
    final selected = types.contains(_type)
        ? _type
        : ManagedNetworkType.fallback;

    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FieldLabel('Name'),
          TextField(
            controller: _name,
            autofocus: true,
            enabled: !submitting,
            maxLength: gridNameMaxLength,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(selected),
            style: kFieldTextStyle,
            decoration: const InputDecoration(
              hintText: 'my-team-grid',
              counterText: '',
            ),
          ),
          const SizedBox(height: 14),
          GridTypePicker(
            value: selected,
            types: types,
            domain: domain,
            enabled: !submitting,
            onChanged: (value) => setState(() => _type = value),
          ),
          const SizedBox(height: 8),
          Text(
            accessDescriptionFor(selected, domain: domain),
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            ErrorBox(message: error),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: submitting ? null : () => _submit(selected),
              child: submitting
                  ? const AppSpinner.onAccent()
                  : const Text('Create grid'),
            ),
          ),
        ],
      ),
    );
  }
}
