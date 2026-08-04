import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/skeleton.dart';
import '../../logic/connector.dart';
import '../../logic/connector_tools_service.dart';

/// "What can I actually do with this?" — answered inside the details dialog.
///
/// The dialog already said the connector is ready; this says what ready buys
/// you. Before it existed the honest answer was nowhere in the app: the tools
/// were real, an agent could call all 23 of Gmail's, and the only way to see
/// them was to ask an agent and hope.
///
/// **A list, not a grid, and one line per tool.** Measured against Gmail's real
/// answer on 2026-08-04: 23 tools, longest name 27 characters, longest
/// description 188 — which is three wrapped lines in this dialog's 460px. Three
/// lines times 23 is a wall nobody reads, so the description is clamped to one
/// and the name carries the meaning.
class ConnectorToolsPanel extends ConsumerWidget {
  const ConnectorToolsPanel({super.key, required this.connector});

  final Connector connector;

  /// The list scrolls past this rather than growing the dialog.
  ///
  /// **Scaled to the window, not fixed.** The first version was a flat 232px —
  /// about five rows — which on a 1080p display showed a fifth of Gmail's 23
  /// tools while most of the screen sat empty. A tall window should spend its
  /// height on the list, since the list is the only part of this dialog that
  /// has more to show.
  ///
  /// The floor keeps a short window usable and the ceiling stops a very tall
  /// one from turning the panel into the whole dialog; the dialog's own
  /// `maxHeight` (72% of the window) is what actually binds on small screens,
  /// and the two are deliberately allowed to overlap rather than being kept in
  /// sync by arithmetic that would drift.
  static double _maxListHeight(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.42).clamp(232, 460);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final token = connector.token;
    if (token == null) return const SizedBox.shrink();

    final tools = ref.watch(
      connectorToolsProvider(
        ConnectorToolsRequest(connectorId: connector.id, token: token),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 20),
        _Heading(
          count: switch (tools) {
            // Only a real answer gets a count. A number that appears while
            // loading and then changes reads as the app correcting itself.
            AsyncValue(value: ConnectorToolsLoaded(:final tools)) =>
              tools.length,
            _ => null,
          },
        ),
        const SizedBox(height: 10),
        switch (tools) {
          // `value?` rather than `AsyncData`: a family provider that is
          // refetching is `AsyncLoading` *carrying the previous value*, and
          // matching on `AsyncData` alone blanks the list on every rebuild.
          AsyncValue(value: final result?) => _Result(result: result),
          AsyncValue(:final error?) => _Message(
            // The type, not the object: an HttpException's `toString` carries
            // the URL, and that URL has a credential attached to it.
            'Grid could not reach this connector just now '
            '(${error.runtimeType}).',
          ),
          _ => const _Loading(),
        },
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({this.count});

  final int? count;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Text(
          'What you can do with this',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: AppPalette.textSecondary,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFont.medium,
              color: AppPalette.textFaint,
            ),
          ),
        ],
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.result});

  final ConnectorToolsResult result;

  @override
  Widget build(BuildContext context) {
    switch (result) {
      case ConnectorToolsUnavailable(:final message):
        return _Message(message);
      case ConnectorToolsLoaded(:final tools):
        if (tools.isEmpty) {
          // Not an error, and phrased so it does not read as one: the sign-in
          // worked and there is nothing for the user to fix.
          return const _Message(
            'This connection works, but the service has not published anything '
            'for Grid to use yet.',
          );
        }
        return _ToolList(tools: tools);
    }
  }
}

class _ToolList extends StatelessWidget {
  const _ToolList({required this.tools});

  final List<ConnectorTool> tools;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      constraints: BoxConstraints(
        maxHeight: ConnectorToolsPanel._maxListHeight(context),
      ),
      decoration: BoxDecoration(
        // Inset, not the dialog's own fill: this is a box set *into* the
        // dialog, and matching the dialog would leave it with no edge at all.
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      clipBehavior: Clip.antiAlias,
      // Fade the two edges rather than cut them.
      //
      // A scrolled list ends mid-row by definition, and measurement confirmed
      // the layout is doing that correctly — nothing is clipped that shouldn't
      // be. The problem is what a hard cut *reads* as: a half-height line of
      // description with its name sliced off looks like a rendering fault
      // rather than like more list. A fade says "this continues" in the one
      // language a scroll region has.
      child: ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // Short stops: long enough to soften a cut row, short enough that a
          // fully visible first row is not dimmed for no reason.
          colors: [
            Colors.transparent,
            Colors.black,
            Colors.black,
            Colors.transparent,
          ],
          stops: [0, 0.06, 0.94, 1],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: Scrollbar(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 4),
            shrinkWrap: true,
            itemCount: tools.length,
            separatorBuilder: (_, _) => const SizedBox(height: 1),
            itemBuilder: (_, index) => _ToolRow(tool: tools[index]),
          ),
        ),
      ),
    );
  }
}

/// One tool: what it is called, and what it does, on one line each.
///
/// The provider's raw name (`add_sheet`) is deliberately not shown. It was
/// briefly a tooltip, which turned out to be the wrong trade in a list: the
/// popup covered the rows underneath it while the user was still scanning
/// them, to reveal an identifier the humanised label already says.
class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.tool});

  final ConnectorTool tool;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tool.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
            ),
          ),
          if (tool.description.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              tool.description,
              // **One, and the taller dialog is the reason it stays one.**
              // Two lines was tried when the dialog widened, and measured
              // against the real 23-tool list it made things worse: row pitch
              // went 39px → 68px, so the panel showed 6.7 rows at 1080p and
              // 4.9 on a 13" — fewer than the 5 the short panel managed. The
              // extra height went into the rows instead of into the list.
              // Wider already recovers most of what one line was clipping.
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: AppPalette.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Three placeholder rows while the provider is asked.
///
/// Three rather than the real count, which is not known until the answer
/// arrives — and rather than a spinner, which would say "working" without
/// saying what is coming.
class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      decoration: BoxDecoration(
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            const SkeletonLine(widthFactor: 0.34, height: 11),
            const SizedBox(height: 6),
            SkeletonLine(widthFactor: [0.8, 0.62, 0.72][i], height: 10),
          ],
        ],
      ),
    );
  }
}

/// A sentence where a list would be, on the same inset so the block keeps its
/// shape whichever way it ends.
class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.45,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}
