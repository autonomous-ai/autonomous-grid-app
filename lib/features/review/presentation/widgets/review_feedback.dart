import 'package:flutter/material.dart';

import '../../../../shared/widgets/toast.dart';

/// Shows [message] over the surface.
///
/// One helper rather than a `ToastScope.show` at each call site: a refused Git
/// command has to surface the same way whether it was a tick on a row, a
/// "include everything" from the menu, or a push — three shapes of the same
/// failure would read as three different problems.
void showReviewFailure(BuildContext context, String message) => ToastScope.show(
  context,
  ToastSpec(message: message, severity: ToastSeverity.error),
);
