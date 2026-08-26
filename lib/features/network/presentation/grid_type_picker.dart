import 'package:flutter/material.dart';

import '../../../infrastructure/api/models/managed_network.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../logic/grid_access_types.dart';

/// Who can reach the grid, as the app's select field.
///
/// It was a two-cell segmented control, and that was right while the question
/// had two answers: laid out flat, both were readable before you touched
/// anything. A third answer broke it — three glyph-less cells in a dialog-width
/// row squeeze every label to a word and still read as a toolbar rather than a
/// setting, and the option that matters most is often the one hidden entirely
/// (see [types]).
///
/// So it is [AppSelectField], the control the rest of the app already uses for
/// "pick one of these" — not a second menu built here. Closed it shows the
/// chosen rule; open it shows each rule with the sentence explaining it.
///
/// [types] is passed in rather than read from `ManagedNetworkType.values`: the
/// domain rule is only offered to accounts that can actually use it (see
/// `accessTypesFor`), and a picker that decided that for itself would need its
/// own copy of a rule the server owns.
class GridTypePicker extends StatelessWidget {
  const GridTypePicker({
    super.key,
    required this.value,
    required this.types,
    required this.enabled,
    required this.onChanged,
    this.label = 'Who can join',
    this.fill,
    this.domain,
  });

  final ManagedNetworkType value;

  /// The rules to show, in order. See `accessTypesFor`.
  final List<ManagedNetworkType> types;

  final bool enabled;
  final ValueChanged<ManagedNetworkType> onChanged;

  /// Field label, defaulted so both create screens ask in the same words (§5).
  ///
  /// It was "Type", which named nothing — the answer to "type of what?" lived
  /// only in the line underneath — while the first-run screen asked the same
  /// question differently. They already share this widget; sharing the words is
  /// the rest of it. The share sheet passes an empty string: it has "General
  /// access" as a heading already, and saying it twice is not saying it better.
  final String label;

  /// Surface override for a field on a raised row — see [AppSelectField.fill].
  final Color? fill;

  /// The email domain the domain rule would admit, when there is one. Named in
  /// the option rather than left as "My domain": this is the one control whose
  /// whole question is *which* domain gets in.
  final String? domain;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: IgnorePointer(
        ignoring: !enabled,
        child: AppSelectField<ManagedNetworkType>(
          label: label,
          showLabel: label.isNotEmpty,
          value: value,
          // The detail is a SENTENCE, and the closed field is only as wide as
          // the control — it would arrive clipped mid-clause and read as a
          // rendering bug. The open menu shows it whole, which is where it is
          // needed: while choosing, not after. Callers print it under the field
          // for the rule already picked.
          showDetailInField: false,
          // Both create-grid forms put this directly under a bordered `Name`
          // field. Without the rim the two controls in one short form read as
          // different kinds of thing, and the softer one looks unresolved
          // beside the crisp one.
          outlined: true,
          fill: fill,
          options: [
            for (final type in types)
              AppSelectOption(
                value: type,
                label: accessLabelFor(type, domain: domain),
                detail: accessDescriptionFor(type, domain: domain),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
