/// [plural] lives in `lib/core` now, where the CLI parsers under
/// `infrastructure` can reach it — they write copy too, and a layer that far
/// down doesn't import `shared`. Still importable from here, where every screen
/// has always found it.
library;

export '../../core/plural.dart';
