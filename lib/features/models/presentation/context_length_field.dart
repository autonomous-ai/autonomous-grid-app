import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/context_length.dart';
import '../../../shared/widgets/context_window_field.dart';
import '../logic/models_providers.dart';

/// The context-window setting for the **built-in** engine: the shared
/// [ContextWindowField], bounded by what the picked model's GGUF says it can
/// take.
///
/// The maximum comes from `grid ctx --json`, so the slider never offers more
/// context than the model supports. If the maximum can't be read the setting
/// hides and the engine uses its own default — a slider whose ceiling is a
/// guess would be worse than not asking at all.
class ContextLengthField extends ConsumerWidget {
  const ContextLengthField({
    super.key,
    required this.model,
    required this.value,
    required this.onChanged,
  });

  /// GGUF filename whose maximum context bounds the slider.
  final String model;

  /// The user's chosen context length in tokens, or null to sit at the default
  /// ([defaultContextLength] for the model's maximum).
  final int? value;

  /// Reports the picked context length (already snapped to 1k) as the user
  /// drags.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxContext = ref.watch(modelMaxContextProvider(model));
    return maxContext.when(
      loading: () =>
          const ContextWindowLoadingTile(message: 'Reading the model limit…'),
      error: (_, _) => const SizedBox.shrink(),
      data: (max) {
        if (max == null || max <= minContextTokens) {
          return const SizedBox.shrink();
        }
        return ContextWindowField(
          max: max,
          value: value == null
              ? defaultContextLength(max)
              : value!.clamp(minContextTokens, max),
          onChanged: onChanged,
        );
      },
    );
  }
}
