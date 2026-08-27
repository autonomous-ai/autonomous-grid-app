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
import '../../../network/logic/grid_sync_controller.dart';
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
  const NewGridForm({super.key, required this.open, required this.onToggle});

  /// Whether the form is showing under its own header row.
  final bool open;

  /// Opens and shuts it. Owned by the screen, because opening this is also what
  /// clears the grid selected in the list — one of the two is the answer, never
  /// both.
  final VoidCallback onToggle;

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
    // Created on the control plane, not yet written here by `grid sync`. Pull
    // again rather than telling the user to press "Refresh" — that link is
    // gone, and copy naming a control that isn't on the screen is the exact
    // failure §5 is about. The row appears in the list above when this lands.
    ref.read(gridSyncControllerProvider.notifier).sync();
    setState(() {
      _warning =
          done.joinWarning ??
          'Grid “${done.network.name}” was created. Fetching it onto this '
              'computer now.';
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

    // A dashed rim, and the one on this screen. Every other surface here is a
    // grid that exists; this is the outline of one that doesn't yet, which is
    // what a dashed edge has meant since long before this app.
    return AnimatedContainer(
      duration: AppMotion.fold,
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        color: AppPalette.panelBg,
        borderRadius: BorderRadius.circular(11),
      ),
      foregroundDecoration: _DashedRim(
        color: widget.open ? AppPalette.accentMuted : AppPalette.textFaint,
        radius: 11,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CreateHeader(open: widget.open, onTap: widget.onToggle),
          if (widget.open)
            _body(context, selected, submitting, error, types, domain),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    ManagedNetworkType selected,
    bool submitting,
    String? error,
    List<ManagedNetworkType> types,
    String? domain,
  ) {
    // Indented past the glyph above it, so the fields read as belonging to the
    // row that revealed them rather than as a second list.
    return Padding(
      padding: const EdgeInsets.fromLTRB(45, 4, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FieldLabel('Name it'),
          TextField(
            controller: _name,
            autofocus: true,
            enabled: !submitting,
            maxLength: gridNameMaxLength,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(selected),
            style: kFieldTextStyle,
            decoration: const InputDecoration(
              // A name a person would give a thing, not a slug. The hint was
              // `my-team-grid`, and a kebab-case example is an instruction: it
              // tells a non-technical reader the field wants an identifier and
              // that the format matters. Neither is true — this is the display
              // name, and it is what everyone they invite will see.
              hintText: 'Design team',
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

/// The row that opens the create form: what it is, what it costs you, and a
/// caret that turns.
class _CreateHeader extends StatelessWidget {
  const _CreateHeader({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 13, 14, 13),
          child: Row(
            children: [
              Icon(Icons.add, size: 16, color: AppPalette.textSecondary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Start a new grid',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 14,
                        fontWeight: AppFont.semibold,
                        letterSpacing: -0.01 * 14,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Private by default. Invite whoever you want.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12.2,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 13),
              AnimatedRotation(
                turns: open ? 0.25 : 0,
                duration: AppMotion.fold,
                curve: AppMotion.curve,
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dashed rounded rim, which Flutter's `Border` cannot draw.
class _DashedRim extends Decoration {
  const _DashedRim({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DashedRimPainter(color: color, radius: radius);
}

class _DashedRimPainter extends BoxPainter {
  _DashedRimPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration cfg) {
    final size = cfg.size;
    if (size == null) return;
    final rect = RRect.fromRectAndRadius(
      (offset & size).deflate(0.5),
      Radius.circular(radius),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    // 5 on, 4 off — long enough to read as a dash at this radius, short enough
    // that the corners still look like corners.
    for (final metric in (Path()..addRRect(rect)).computeMetrics()) {
      var start = 0.0;
      while (start < metric.length) {
        final end = (start + 5).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(start, end), paint);
        start = end + 4;
      }
    }
  }
}
