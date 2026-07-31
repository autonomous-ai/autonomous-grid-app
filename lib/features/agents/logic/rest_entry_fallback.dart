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
/// **Every tool here is bounded by the scope the account actually granted**, and
/// that is the rule to keep when adding one. A tool the grant cannot back is
/// worse than no tool at all: the model sees it, calls it, gets a 403, and the
/// user reads a failure where they should have read "this isn't available".
///
/// Measured on 2026-07-31 for the organisation's Google account:
///
/// | connector         | granted                                    | so |
/// |-------------------|--------------------------------------------|----|
/// | `gmail`           | `gmail.send` + `userinfo.*` + `openid`     | send only — no reading tool exists |
/// | `google_calendar` | `calendar.events` + `userinfo.*` + `openid`| events read/write — **not** `calendarList`, **not** `freebusy` |
///
/// `calendar.events` is "view and edit events on all your calendars". Listing
/// the user's *calendars* needs `calendar.readonly` or `calendar`, and a
/// free/busy query needs `calendar.freebusy` — neither was granted, so neither
/// is offered, and everything here addresses `calendars/primary`.
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
  'google_calendar': {
    'auth': {
      'in': 'header',
      'name': 'Authorization',
      'format': 'Bearer {access_token}',
    },
    'tools': [
      {
        'name': 'google_calendar_list_events',
        'description':
            "List events on the user's main Google Calendar, soonest first. "
            'Use this for questions about their schedule, what is coming up, '
            'or whether a time is free. Returns each event with its id, which '
            'google_calendar_delete_event needs.',
        'params': {
          'time_min': {
            'type': 'string',
            'description':
                'Only events ending after this instant. RFC 3339 with an '
                'offset, e.g. 2026-08-01T00:00:00+07:00. Omit for "from now".',
          },
          'time_max': {
            'type': 'string',
            'description':
                'Only events starting before this instant, same format as '
                'time_min. Omit for no upper bound.',
          },
          'query': {
            'type': 'string',
            'description':
                'Free-text search over the events. Omit to list all.',
          },
          'max_results': {
            'type': 'integer',
            'description': 'How many events to return. Omit for the default.',
          },
        },
        'request': {
          'method': 'GET',
          'url':
              'https://www.googleapis.com/calendar/v3/calendars/primary/events',
          'query': {
            'timeMin': '{time_min}',
            'timeMax': '{time_max}',
            'q': '{query}',
            'maxResults': '{max_results}',
            // Expand recurring events into their occurrences, which is what
            // anyone asking "what's on Tuesday" means. `orderBy=startTime` is
            // only legal alongside it, so the two are set together.
            'singleEvents': 'true',
            'orderBy': 'startTime',
          },
        },
      },
      {
        'name': 'google_calendar_create_event',
        'description': "Add an event to the user's main Google Calendar.",
        'params': {
          'summary': {
            'type': 'string',
            'required': true,
            'description': 'Event title, as it appears in the calendar.',
          },
          'start': {
            'type': 'string',
            'required': true,
            'description':
                'Start time, RFC 3339 **with a UTC offset**, e.g. '
                '2026-08-01T09:00:00+07:00. Without an offset Google rejects '
                'the request.',
          },
          'end': {
            'type': 'string',
            'required': true,
            'description': 'End time, same format as start.',
          },
          'description': {
            'type': 'string',
            'description': 'Longer notes on the event. Optional.',
          },
          'location': {
            'type': 'string',
            'description': 'Where it happens. Optional.',
          },
        },
        'request': {
          'method': 'POST',
          'url':
              'https://www.googleapis.com/calendar/v3/calendars/primary/events',
          'json': {
            'summary': '{summary}',
            'description': '{description}',
            'location': '{location}',
            'start': {'dateTime': '{start}'},
            'end': {'dateTime': '{end}'},
          },
        },
      },
      {
        'name': 'google_calendar_delete_event',
        'description':
            "Delete an event from the user's main Google Calendar. Get the id "
            'from google_calendar_list_events first — this cannot be undone.',
        'params': {
          'event_id': {
            'type': 'string',
            'required': true,
            'description':
                'The event id returned by google_calendar_list_events.',
          },
        },
        'request': {
          'method': 'DELETE',
          'url':
              'https://www.googleapis.com/calendar/v3/calendars/primary/events/{event_id}',
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
