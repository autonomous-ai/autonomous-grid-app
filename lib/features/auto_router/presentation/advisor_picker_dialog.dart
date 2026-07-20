import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../plugins/presentation/widgets/extension_tile_surface.dart';
import '../logic/auto_router_controller.dart';
import '../logic/auto_router_models.dart';

/// Opens the advisor picker and returns the chosen `provider:model` tokens in
/// priority order, or null if the user cancelled. [current] pre-checks the
/// advisors already on the chain.
Future<List<String>?> showAdvisorPicker(
  BuildContext context,
  WidgetRef ref, {
  required List<String> current,
}) => showDialog<List<String>>(
  context: context,
  builder: (_) => _AdvisorPickerDialog(initial: current),
);

/// Picks up to [kMaxAdvisors] advisors from the platform catalog.
///
/// Selection is **order-preserving** — the first picked is tried first, and
/// [AutoRouterController.setAdvisors] passes the list to the CLI verbatim. The
/// old dialog stated that in prose ("the first is tried first") while rendering
/// plain checkboxes, so the priority was real but invisible: three ticks in a
/// column, no way to see which led or to reorder them. The rank badge and the
/// "tried first / then / last" line make that order visible, and picking a
/// checked row again moves it to the end of the chain rather than doing nothing.
class _AdvisorPickerDialog extends ConsumerStatefulWidget {
  const _AdvisorPickerDialog({required this.initial});

  final List<String> initial;

  @override
  ConsumerState<_AdvisorPickerDialog> createState() =>
      _AdvisorPickerDialogState();
}

/// The dialog's width, applied to both the title and the content.
///
/// A single constant on purpose: [AlertDialog] takes the wider of the two, so
/// letting either size itself hands the width to whichever string happens to be
/// longest.
const double _dialogWidth = 420;

class _AdvisorPickerDialogState extends ConsumerState<_AdvisorPickerDialog> {
  late final List<String> _selected = [...widget.initial];

  /// Adds an advisor to the end of the chain, or drops it.
  void _toggle(String token) {
    setState(() {
      if (_selected.contains(token)) {
        _selected.remove(token);
      } else if (_selected.length < kMaxAdvisors) {
        _selected.add(token);
      }
    });
  }

  /// Moves an already-picked advisor one place earlier in the chain.
  void _promote(String token) {
    final index = _selected.indexOf(token);
    if (index <= 0) return;
    setState(() {
      _selected.removeAt(index);
      _selected.insert(index - 1, token);
    });
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final catalog = ref.watch(advisorCatalogProvider);

    return AlertDialog(
      surfaceTintColor: Colors.transparent,
      titlePadding: const EdgeInsets.fromLTRB(26, 22, 26, 0),
      contentPadding: const EdgeInsets.fromLTRB(26, 12, 26, 0),
      actionsPadding: const EdgeInsets.fromLTRB(26, 14, 22, 20),
      // Width is pinned on the *title* as well as the content: AlertDialog sizes
      // itself to whichever of the two is wider, so an unconstrained title made
      // the one-sentence subtitle set the dialog's width and stretched it far
      // past the content's own 420.
      title: SizedBox(
        width: _dialogWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose advisors',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'A cloud AI that reads each request and picks which of your grid’s '
              'models answers it. It only decides — your models do the work.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
      // Height is a *ceiling*, not a fixed size: with one provider and four
      // models the old fixed 440 left a large dead band above the buttons. The
      // list shrink-wraps and only starts scrolling past the cap.
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: SizedBox(
          width: _dialogWidth,
          child: catalog.when(
            data: _body,
            error: (error, _) => _ErrorNote(message: '$error'),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: AppSpinner()),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _body(AdvisorCatalog catalog) {
    if (catalog.providers.isEmpty) {
      return const _EmptyNote();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChainSummary(selected: _selected),
        const SizedBox(height: 14),
        // Flexible + shrinkWrap, not Expanded: a short catalog sizes the dialog
        // to its rows instead of padding out to the cap.
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              // Grouped by provider, so the repeated `openai:` prefix becomes one
              // heading instead of a word on every row.
              for (final (i, provider) in catalog.providers.indexed) ...[
                // Between groups only — a trailing gap after the last one reads
                // as the list not having ended.
                if (i > 0) const SizedBox(height: 14),
                ExtensionSectionHeader(
                  label: provider.provider,
                  count: provider.models.length,
                ),
                for (final (j, model) in provider.models.indexed) ...[
                  if (j > 0) const SizedBox(height: 6),
                  _AdvisorRow(
                    label: model,
                    isDefault: model == provider.defaultModel,
                    rank: _rankOf('${provider.provider}:$model'),
                    atCap: _selected.length >= kMaxAdvisors,
                    onTap: () => _toggle('${provider.provider}:$model'),
                    onPromote: () => _promote('${provider.provider}:$model'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 1-based position in the chain, or null when not picked.
  int? _rankOf(String token) {
    final index = _selected.indexOf(token);
    return index < 0 ? null : index + 1;
  }
}

/// The chain as a sentence: which advisor is tried first, and what follows.
///
/// This is the fact the dialog exists to set, and the old prose stated it
/// without ever showing the result. Empty state doubles as the instruction, so
/// there's no separate hint line to fall out of sync.
class _ChainSummary extends StatelessWidget {
  const _ChainSummary({required this.selected});

  final List<String> selected;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);

    if (selected.isEmpty) {
      return _Note(
        icon: Icons.touch_app_outlined,
        child: Text(
          'Pick up to $kMaxAdvisors. The first one you pick is tried first.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
      );
    }

    return _Note(
      icon: Icons.route_outlined,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < selected.length; i++) ...[
            if (i > 0)
              // Same 3.0 glyph floor as the add icon — textFaint fails it here.
              Icon(
                Icons.arrow_right_alt_rounded,
                size: 15,
                color: AppPalette.textSecondary,
              ),
            _ChainStep(rank: i + 1, token: selected[i]),
          ],
        ],
      ),
    );
  }
}

/// One advisor in the summary chain — its rank and its model name.
class _ChainStep extends StatelessWidget {
  const _ChainStep({required this.rank, required this.token});

  final int rank;
  final String token;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Only the model name: the provider is already the group heading the row
    // came from, and repeating it here makes the chain unreadable at a glance.
    final model = token.contains(':') ? token.split(':').last : token;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 9, 3),
      decoration: BoxDecoration(
        color: AppCard.tint18,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RankBadge(rank: rank),
          const SizedBox(width: 6),
          Text(
            model,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              // Plain ink, not the accent: accentStrong on the chip's own tinted
              // fill is 3.76:1 in dark. The rank disc beside it already carries
              // the accent, so the chip doesn't need to repeat it.
              color: AppPalette.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The priority number, as a filled disc.
class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      width: 17,
      height: 17,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        // AppPalette.accent, not AppCard.accentStrong: accentStrong lightens in
        // dark (#5C7CFF), where white on it measures 3.63:1 — under 4.5 for text
        // this small. The flat accent is one value in both themes and carries
        // white at 5.52:1.
        color: AppPalette.accent,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$rank',
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          height: 1,
          // On the accent disc in both themes, so it can't take a theme colour.
          color: Colors.white,
        ),
      ),
    );
  }
}

/// One advisor the catalog offers.
///
/// Deliberately not a `CheckboxListTile`: that control is unthemed here, brings
/// Material's own padding and 14pt type, and — more importantly — a checkbox can
/// only say yes/no, while this choice carries a rank. Picked rows show their
/// position and an arrow to move up instead.
class _AdvisorRow extends StatelessWidget {
  const _AdvisorRow({
    required this.label,
    required this.isDefault,
    required this.rank,
    required this.atCap,
    required this.onTap,
    required this.onPromote,
  });

  final String label;
  final bool isDefault;
  final int? rank;
  final bool atCap;
  final VoidCallback onTap;
  final VoidCallback onPromote;

  bool get _picked => rank != null;

  /// At the cap, an unpicked row can't be added — but a picked one must stay
  /// interactive so the chain can still be changed without cancelling out.
  bool get _disabled => atCap && !_picked;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppCard.insetRadius);

    return Opacity(
      opacity: _disabled ? 0.45 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: _disabled ? null : onTap,
          borderRadius: radius,
          hoverColor: AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              // tint25, not accentWash: against the bubbleFill row the wash
              // measures 1.046:1 in dark and 1.006:1 in light — a hue shift with
              // almost no luminance change, so picked and unpicked rows read as
              // the same row. tint25 gives 1.171 / 1.206.
              color: _picked ? AppCard.tint25 : AppGlass.bubbleFill,
              borderRadius: radius,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: rank == null
                      // textSecondary, not textFaint: faint measures 2.30:1 on
                      // the light row, under WCAG 1.4.11's 3.0 for a UI glyph.
                      ? Icon(
                          Icons.add_circle_outline,
                          size: 16,
                          color: AppPalette.textSecondary,
                        )
                      : _RankBadge(rank: rank!),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppControl.fontSize,
                      height: 1.2,
                      fontWeight: _picked ? FontWeight.w600 : FontWeight.w400,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                ),
                if (isDefault) ...[
                  const SizedBox(width: 8),
                  const ExtensionTag(label: 'Default', muted: true),
                ],
                // A fixed slot, kept even when empty: the arrow only applies from
                // second place, and letting it appear and vanish would shift the
                // label of every row each time the chain is reordered.
                const SizedBox(width: 4),
                SizedBox(
                  width: 28,
                  child: rank != null && rank! > 1
                      ? IconButton(
                          icon: const Icon(Icons.arrow_upward_rounded, size: 15),
                          tooltip: 'Try this one earlier',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          color: AppPalette.textSecondary,
                          onPressed: onPromote,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A quiet framed note — the shared shape for the chain summary and the empty
/// and error states, so all three sit on the same surface.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.child});

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppGlass.bubbleFill,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppPalette.textSecondary),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 22, color: AppPalette.textFaint),
          const SizedBox(height: 10),
          Text(
            'No advisors are available right now.',
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 22,
              color: AppPalette.warn,
            ),
            const SizedBox(height: 10),
            Text(
              "Couldn't load the advisor list.",
              style: TextStyle(fontSize: 13, color: AppPalette.textPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
