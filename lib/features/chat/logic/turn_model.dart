/// The model a turn started away from the composer answers with — from the
/// Grid Panel, from a Telegram message: the first of [candidates] that names
/// one, or '' when none does and there is nothing to answer with.
///
/// Callers list the remembered choices first and what the grid serves last.
/// The remembered ones are taken as they stand rather than checked against the
/// grid's list: that list is fetched, and it is empty for the first moment of a
/// session and on every refresh — checking against it would turn a turn into
/// "no model available" over a grid serving a dozen.
String firstModelChoice(Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final model = candidate?.trim() ?? '';
    if (model.isNotEmpty) return model;
  }
  return '';
}
