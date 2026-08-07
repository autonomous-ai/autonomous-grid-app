/// Real `-z` output from Git separates its fields with NUL bytes, which are
/// invisible in a source file and impossible to review in a diff.
///
/// The fixtures in these tests write `|` where the byte goes; this puts the
/// real one back, so the parsers are still exercised against the bytes they
/// will actually be handed.
String z(String fixture) => fixture.replaceAll('|', '\u0000');
