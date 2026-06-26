/// Name for a user's auto-provisioned first grid, derived from their email:
/// `huy@gmail.com` → `Huy Grid`, `john.doe@x.com` → `John Grid`. Falls back to
/// `My Grid` when there's no usable email (so the create call never gets a
/// blank name).
String defaultGridName(String? email) {
  final local = (email ?? '').split('@').first;
  final firstName = local
      .split(RegExp(r'[._+\-]'))
      .firstWhere((part) => part.isNotEmpty, orElse: () => '');
  if (firstName.isEmpty) return 'My Grid';
  return '${firstName[0].toUpperCase()}${firstName.substring(1).toLowerCase()} Grid';
}
