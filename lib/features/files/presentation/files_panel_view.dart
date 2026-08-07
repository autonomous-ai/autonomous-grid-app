import 'package:flutter/material.dart';

import '../../../shared/widgets/panel_body.dart';

/// The project's files, in a preview-panel tab: a tree to pick from and the
/// file you picked.
///
/// The one feature that needs all four regions — breadcrumb, file, and the tree
/// in the side column ([PanelBody.side]).
class FilesPanelView extends StatelessWidget {
  const FilesPanelView({super.key});

  @override
  Widget build(BuildContext context) => const PanelBody(
    toolbar: PanelTodo('Files breadcrumb', dense: true),
    main: PanelTodo('Files'),
    side: PanelTodo('Files — workspace tree'),
  );
}
