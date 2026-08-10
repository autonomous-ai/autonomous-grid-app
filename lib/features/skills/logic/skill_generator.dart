import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../playground/logic/one_shot_target.dart';

/// The three fields a generated draft fills in, matching the skill form.
typedef GeneratedSkill = ({
  String name,
  String description,
  String instructions,
});

/// A generation that couldn't finish, carrying a plain-language line safe to
/// show the user — no model ready, the model refused, an unreadable answer. The
/// dialog surfaces [message] verbatim.
class SkillGenerationException implements Exception {
  const SkillGenerationException(this.message);

  final String message;
}

/// Drafts a skill from a rough idea using whatever model can already answer —
/// the local engine if one is serving, else the selected grid's relay — so the
/// user gets a full name / when-to-use / steps to edit instead of a blank form.
///
/// One blocking `chat/completions` call (via the shared [ChatTransport]); the
/// model is told to return a small JSON object we parse back into the form.
class SkillGenerator {
  const SkillGenerator(this._ref);

  final Ref _ref;

  Future<GeneratedSkill> generate(String idea) async {
    final trimmed = idea.trim();
    if (trimmed.isEmpty) {
      throw const SkillGenerationException(
        'Type a rough idea first — even a few words like "weekly report".',
      );
    }

    final target = _resolveTarget();
    final messages = _promptFor(trimmed);
    final log = _ref.read(commandLogProvider.notifier);
    final id = log.begin(
      CliCallKind.http,
      'POST ${target.endpoint}',
      detail: CommandDetail.json(
        chatCompletionsPayload(model: target.model, messages: messages),
        authorized: target.apiKey.isNotEmpty,
      ),
    );
    final (reply, error) = await _ref
        .read(chatTransportProvider)
        .complete(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
          messages: messages,
        );
    log.finish(
      id,
      exitCode: error?.statusCode ?? 200,
      error: error?.message,
      responseBody: reply,
    );

    if (error != null) {
      throw SkillGenerationException(
        friendlyOneShotError(error, what: 'draft the skill'),
      );
    }

    final draft = parseGeneratedSkill(reply ?? '');
    if (draft == null) {
      throw const SkillGenerationException(
        "Couldn't turn the model's answer into a skill — try again, or add "
        'more detail to the idea.',
      );
    }
    return draft;
  }

  /// Where to send the request — the local engine, else the grid's relay.
  /// Throws a guiding line when nothing can answer yet.
  OneShotTarget _resolveTarget() {
    final target = resolveOneShotTarget(_ref);
    if (target != null) return target;
    throw SkillGenerationException(noModelReady('write it'));
  }

  static List<Map<String, dynamic>> _promptFor(String idea) => [
    {
      'role': 'system',
      'content':
          'You write "skills" for an AI assistant — a short instruction card '
          'the assistant follows for one job. From the user\'s rough idea, '
          'reply with ONLY a JSON object (no prose, no code fence) with '
          'exactly these keys:\n'
          '- "name": a short title, 2-4 words, in Title Case.\n'
          '- "description": one sentence starting with "Use when", telling the '
          'assistant when to reach for this skill.\n'
          '- "instructions": clear step-by-step directions for the assistant, '
          'as plain text with short numbered steps.\n'
          'Write for a non-technical user. Be practical and specific.',
    },
    {'role': 'user', 'content': idea},
  ];
}

/// Wire [SkillGenerator] through the container so the dialog stays testable — a
/// fake transport swaps in without a live model.
final skillGeneratorProvider = Provider<SkillGenerator>(
  (ref) => SkillGenerator(ref),
);

/// Reads the model's answer back into the three form fields.
///
/// Forgiving on purpose: a model may wrap its JSON in a code fence or a
/// sentence, so we take the outermost `{ … }` and decode that. Returns null when
/// there's no object, it isn't valid JSON, or it lacks the parts a skill needs
/// (a name and instructions) — the caller then asks the user to try again rather
/// than saving a half-empty skill.
GeneratedSkill? parseGeneratedSkill(String raw) {
  final object = _outermostJsonObject(raw);
  if (object == null) return null;

  final Object? decoded;
  try {
    decoded = jsonDecode(object);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;

  final name = _stringField(decoded['name']);
  final instructions = _stringField(decoded['instructions']);
  if (name.isEmpty || instructions.isEmpty) return null;

  return (
    name: name,
    description: _stringField(decoded['description']),
    instructions: instructions,
  );
}

String _stringField(Object? value) => value is String ? value.trim() : '';

String? _outermostJsonObject(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start == -1 || end <= start) return null;
  return raw.substring(start, end + 1);
}
