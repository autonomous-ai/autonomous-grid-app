import 'package:flutter/material.dart';

import '../../../shared/widgets/panel_body.dart';

/// Review, in a preview-panel tab: what the assistant changed, and whether it
/// should stay.
///
/// Takes the side column ([PanelBody.side]) for the list of changed files — a
/// diff you can't navigate by file is a diff you scroll past.
class ReviewPanelView extends StatelessWidget {
  const ReviewPanelView({super.key});

  @override
  Widget build(BuildContext context) => const PanelBody(
    toolbar: PanelTodo('Review toolbar', dense: true),
    main: PanelTodo('Review'),
    side: PanelTodo('Review — changed files'),
  );
}
