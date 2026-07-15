/// A reusable message the user saved to insert into the composer with `/`.
///
/// [name] is what shows in the slash menu (and what they type after `/` to find
/// it); [body] is the text dropped into the composer. Kept deliberately plain —
/// a prompt is just named boilerplate, not a skill Hermes reasons about.
class SavedPrompt {
  const SavedPrompt({required this.id, required this.name, required this.body});

  /// Stable id, assigned once when the prompt is created, so edits and deletes
  /// target the right entry even after a rename.
  final String id;

  /// The short label shown in the `/` menu, e.g. `Weekly report`.
  final String name;

  /// The message inserted into the composer when the prompt is picked.
  final String body;

  SavedPrompt copyWith({String? name, String? body}) =>
      SavedPrompt(id: id, name: name ?? this.name, body: body ?? this.body);

  /// Reads one prompt, or null when the entry is missing the fields it needs —
  /// a hand-edited or partially-written file drops bad rows instead of throwing.
  static SavedPrompt? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final body = raw['body'];
    if (id is! String || name is! String || body is! String) return null;
    if (id.isEmpty || name.trim().isEmpty) return null;
    return SavedPrompt(id: id, name: name, body: body);
  }

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'body': body};

  @override
  bool operator ==(Object other) =>
      other is SavedPrompt &&
      other.id == id &&
      other.name == name &&
      other.body == body;

  @override
  int get hashCode => Object.hash(id, name, body);
}
