/// Grid's design system, re-exported from the package both apps share.
///
/// The tokens moved to `packages/grid_theme` when Grid on a phone had to resolve
/// against the same palette — see that package's pubspec for why the desktop app
/// cannot be the shared copy. This file stays because 238 files import it by
/// this path, and a move that rewrites 238 imports is a diff nobody can review.
library;

export 'package:grid_theme/grid_theme.dart';
