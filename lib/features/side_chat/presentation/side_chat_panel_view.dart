import 'package:flutter/material.dart';

import '../../../shared/widgets/panel_body.dart';

/// A second conversation, in a preview-panel tab — somewhere to ask a question
/// without derailing the one you're having.
///
/// No side column: it is a transcript and a composer, and it is already the
/// narrow half of the window.
class SideChatPanelView extends StatelessWidget {
  const SideChatPanelView({super.key});

  @override
  Widget build(BuildContext context) => const PanelBody(
    toolbar: PanelTodo('Side chat toolbar', dense: true),
    main: PanelTodo('Side chat'),
  );
}
