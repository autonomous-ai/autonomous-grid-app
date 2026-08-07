import 'package:flutter/material.dart';

import '../../../shared/widgets/panel_body.dart';

/// A browser, in a preview-panel tab — the page the assistant is driving, next
/// to the conversation driving it.
///
/// No side column: the toolbar carries the address, and the page takes the rest.
class BrowserPanelView extends StatelessWidget {
  const BrowserPanelView({super.key});

  @override
  Widget build(BuildContext context) => const PanelBody(
    toolbar: PanelTodo('Browser address bar', dense: true),
    main: PanelTodo('Browser'),
  );
}
