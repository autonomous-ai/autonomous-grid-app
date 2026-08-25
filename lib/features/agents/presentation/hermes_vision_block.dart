import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_environment.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/hermes_vision_controller.dart';

/// Which model Hermes hands an image to — the Agents screen's one Hermes-only
/// setting.
///
/// **Developer builds only.** Hermes's own documentation calls the auxiliary
/// models experimental and warns that overriding them may not work; a setting
/// that can quietly stop images being read is not one to put in front of
/// somebody who did not ask for it. [AppEnvironment.isDeveloperMode] is the same
/// gate the Grids and Debug tabs use, and a shipped build can no more reach this
/// than it can reach staging.
///
/// Empty (draws nothing) outside a dev build, and on any agent that is not
/// Hermes: Codex and Claude Code choose their own vision path and have no
/// equivalent to set.
class HermesVisionBlock extends ConsumerWidget {
  const HermesVisionBlock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!AppEnvironment.isDeveloperMode) return const SizedBox.shrink();
    AppTheme.watch(context);
    final models = ref.watch(visionModelsProvider);
    final chosen = ref.watch(hermesVisionModelProvider);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, color: AppPalette.divider),
          const SizedBox(height: 14),
          Text(
            'Model for images',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: AppFont.medium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _explainer(models.isEmpty),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          if (models.isNotEmpty)
            _Picker(models: models, chosen: chosen.asData?.value),
        ],
      ),
    );
  }

  /// Says which state the grid is in rather than showing an empty picker: a grid
  /// serving no model that reads images has nothing to choose from, and the
  /// screen should say so instead of looking broken (§5).
  static String _explainer(bool empty) => empty
      ? 'Hermes reads attached pictures with a second model. No model on this '
            'grid says it can read images, so it will use its own default.'
      : 'Hermes reads attached pictures with a second model. Pick one this grid '
            'serves and the work stays on the grid instead of going to Hermes’s '
            'own default provider.';
}

/// The picker itself, plus the way back to Hermes's default.
class _Picker extends ConsumerWidget {
  const _Picker({required this.models, required this.chosen});

  final List<String> models;

  /// What the config says today, or null while Hermes decides for itself. Null
  /// is a real state, not a missing one — see [HermesVisionController].
  final String? chosen;

  /// The picker's own row for "let Hermes decide", so clearing the choice is in
  /// the same control as making one rather than a button beside it.
  static const _auto = '';

  Future<void> _pick(BuildContext context, WidgetRef ref, String value) async {
    final controller = ref.read(hermesVisionModelProvider.notifier);
    final failure = value == _auto
        ? await controller.clear()
        : await controller.choose(value);
    if (!context.mounted) return;
    ToastScope.show(
      context,
      failure == null
          ? ToastSpec(
              message: value == _auto
                  ? 'Hermes will pick its own model for images.'
                  : 'Images now go to $value.',
              severity: ToastSeverity.success,
            )
          : ToastSpec(message: failure, severity: ToastSeverity.error),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppSelectField(
      label: 'Model',
      value: chosen ?? _auto,
      options: [
        const AppSelectOption(
          value: _auto,
          label: 'Let Hermes choose',
          detail: 'Its own default provider',
        ),
        for (final model in models) AppSelectOption(value: model, label: model),
      ],
      onChanged: (value) => _pick(context, ref, value),
    );
  }
}
