import 'rest_entry.dart';

/// Stand-in `rest_entry` payloads for connectors the gateway does not describe
/// yet.
///
/// **This is scaffolding, and it is meant to be deleted.** The gateway is the
/// source of truth for how a connector is reached — that is D14 for the catalog
/// and the same rule applies here. A table of provider knowledge living in the
/// app is exactly what this design set out to avoid: it ships on the app's
/// release cadence, it drifts per user, and it makes "add a connector" a Flutter
/// change instead of a backend row.
///
/// It exists for one reason: the architecture cannot be proven end to end
/// without a payload, and the gateway has not shipped `rest_entry` yet. Every
/// byte below is a literal example of what the backend should return, written in
/// exactly the shape [RestEntry.fromJson] parses — so when the gateway does send
/// it, deleting this file is the whole migration.
///
/// **The gateway always wins.** [restEntryFallbackFor] is consulted only when
/// the stored token carries no `rest_entry` of its own, so a backend payload
/// silently supersedes anything here without a flag or a release.
///
/// The Gmail entry is bounded by what the account actually granted — measured on
/// 2026-07-31: `gmail.send`, `userinfo.email`, `userinfo.profile`, `openid`.
/// There is deliberately no reading tool: `gmail.send` does not permit one, and
/// a tool that always fails is worse than a tool that isn't offered.
const Map<String, Map<String, Object?>> _fallbacks = {
  'gmail': {
    'auth': {
      'in': 'header',
      'name': 'Authorization',
      'format': 'Bearer {access_token}',
    },
    'tools': [
      {
        'name': 'gmail_identity',
        'description':
            'Get the email address and profile name of the Google account '
            'connected to Grid. Use this when the user asks which account, '
            'which email address, or who they are signed in as.',
        'params': <String, Object?>{},
        'request': {
          'method': 'GET',
          'url': 'https://www.googleapis.com/oauth2/v3/userinfo',
        },
      },
      {
        'name': 'gmail_send',
        'description':
            'Send an email from the connected Gmail account. This account can '
            'only send — it cannot read, search or list the mailbox.',
        'params': {
          'to': {
            'type': 'string',
            'required': true,
            'description': 'Recipient email address.',
          },
          'subject': {
            'type': 'string',
            'required': true,
            'description': 'Subject line.',
          },
          'body': {
            'type': 'string',
            'required': true,
            'description': 'Plain-text message body.',
          },
        },
        'request': {
          'method': 'POST',
          'url': 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send',
          'json': {
            'raw': {
              r'$encode': 'rfc2822_base64url',
              'to': '{to}',
              'subject': '{subject}',
              'body': '{body}',
            },
          },
        },
      },
    ],
  },
};

/// The stand-in entry for [connector], or null when there is none.
RestEntry? restEntryFallbackFor(String connector) {
  final raw = _fallbacks[connector];
  return raw == null ? null : RestEntry.fromJson(raw);
}
