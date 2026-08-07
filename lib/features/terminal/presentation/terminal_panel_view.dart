import 'package:flutter/material.dart';

import '../../../shared/widgets/panel_body.dart';

/// A terminal session, in a preview-panel tab.
///
/// No side column: the output is the whole point, and a column beside it would
/// only wrap the lines it exists to show.
class TerminalPanelView extends StatelessWidget {
  const TerminalPanelView({super.key});

  @override
  Widget build(BuildContext context) => const PanelBody(
    toolbar: PanelTodo('Terminal toolbar', dense: true),
    main: PanelTodo('Terminal'),
  );
}
