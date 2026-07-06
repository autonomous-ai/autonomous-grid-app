/// Suffix on every auto-provisioned grid name, so a starter grid reads as an AI
/// grid ("Huy" → "Huy AI Grid"). One source so the name/email/fallback branches
/// never drift.
const _gridNameSuffix = 'AI Grid';

/// Name for a user's auto-provisioned first grid. Prefers the first name from
/// their profile ("Đức Nguyễn" → "Đức AI Grid") so it reads naturally and keeps
/// diacritics, then falls back to the email local part ("john.doe@x.com" →
/// "John AI Grid"), and finally "My AI Grid" when neither is usable (so the
/// create call never gets a blank name).
String defaultGridName({String? name, String? email}) {
  final fromName = _firstWord(name, RegExp(r'\s+'));
  if (fromName.isNotEmpty) return '${_capitalize(fromName)} $_gridNameSuffix';

  final local = (email ?? '').split('@').first;
  final fromEmail = _firstWord(local, RegExp(r'[._+\-]'));
  if (fromEmail.isNotEmpty) return '${_capitalize(fromEmail)} $_gridNameSuffix';

  return 'My $_gridNameSuffix';
}

/// First non-empty segment of [value] split on [separator] (whitespace for a
/// display name, punctuation for an email local part).
String _firstWord(String? value, Pattern separator) => (value ?? '')
    .trim()
    .split(separator)
    .firstWhere((part) => part.isNotEmpty, orElse: () => '');

/// Title-case a single word: upper the first letter (diacritics preserved, so
/// "đức" → "Đức"), lower the rest ("JOHN" → "John").
String _capitalize(String word) =>
    '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
