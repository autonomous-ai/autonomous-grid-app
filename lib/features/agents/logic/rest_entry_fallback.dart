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
/// | `google_drive`    | `drive.file` + `userinfo.*` + `openid`     | only files Grid itself created — **not** the user's Drive |
/// | `figma-api-app`   | `file_content:read` + `current_user:read`  | read a file by key — **no** browsing, **no** comments, **no** image rendering |
///
/// `calendar.events` is "view and edit events on all your calendars". Listing
/// the user's *calendars* needs `calendar.readonly` or `calendar`, and a
/// free/busy query needs `calendar.freebusy` — neither was granted, so neither
/// is offered, and everything here addresses `calendars/primary`.
///
/// `drive.file` is the narrowest Drive scope there is: per-file access to what
/// *this OAuth client* created or the user explicitly picked. `files.list`
/// therefore returns Grid's own files and nothing else — it is empty right
/// after connecting. That is not a bug to work around and the tool descriptions
/// say so outright, because the failure mode is not an error: it is the model
/// reporting an empty list as "your Drive is empty".
///
/// Figma grants exactly two scopes, described by Figma as "read the contents of
/// files, such as nodes and the editor type" and "read your name, email, and
/// profile image". Three things are therefore deliberately absent: **listing or
/// searching** files (no endpoint exists without the project scopes), **comments**
/// (`file_comments:read`), and **image rendering** (`GET /v1/images/:key`, whose
/// scope Figma's docs do not state). The last one was probed on 2026-07-31 and
/// the probe could not settle it — Figma answers 404 for an unknown file key
/// *before* checking scope, so a bad key tells you nothing. Unverified means it
/// stays out.
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
  'google_drive': {
    'auth': {
      'in': 'header',
      'name': 'Authorization',
      'format': 'Bearer {access_token}',
    },
    'tools': [
      {
        'name': 'google_drive_list_files',
        'description':
            'List the Drive files Grid can see. This is NOT the whole Drive: '
            'the connection only reaches files Grid itself created, so right '
            'after connecting the list is empty and grows as files are made '
            "with google_drive_create_file. Never tell the user this is all "
            'their Drive contains.',
        'params': {
          'query': {
            'type': 'string',
            'description':
                "Drive query syntax, e.g. name contains 'report'. Omit to "
                'list everything reachable.',
          },
          'page_size': {
            'type': 'integer',
            'description': 'How many files to return. Omit for the default.',
          },
        },
        'request': {
          'method': 'GET',
          'url': 'https://www.googleapis.com/drive/v3/files',
          'query': {
            'q': '{query}',
            'pageSize': '{page_size}',
            // Asked for explicitly: the default response is id and name only,
            // which is not enough to tell two files apart or to answer "when
            // did I write that".
            'fields': 'files(id,name,mimeType,modifiedTime,size,webViewLink)',
            'orderBy': 'modifiedTime desc',
          },
        },
      },
      {
        'name': 'google_drive_read_file',
        'description':
            'Read the contents of a Drive file Grid created. Get the id from '
            'google_drive_list_files. Works for plain text and similar; a '
            'Google Docs/Sheets file is not stored as a file and cannot be '
            'read this way.',
        'params': {
          'file_id': {
            'type': 'string',
            'required': true,
            'description': 'The id from google_drive_list_files.',
          },
        },
        'request': {
          'method': 'GET',
          'url': 'https://www.googleapis.com/drive/v3/files/{file_id}',
          'query': {'alt': 'media'},
        },
      },
      {
        'name': 'google_drive_create_file',
        'description':
            "Save a new text file to the user's Google Drive. Grid keeps "
            'access to whatever it creates, so the file can be listed and read '
            'again afterwards.',
        'params': {
          'name': {
            'type': 'string',
            'required': true,
            'description': 'File name including its extension, e.g. notes.txt.',
          },
          'content': {
            'type': 'string',
            'required': true,
            'description': 'The full text to write into the file.',
          },
          'content_type': {
            'type': 'string',
            'description':
                'MIME type of the content. Omit for text/plain; use text/'
                'markdown, text/csv and so on where it fits.',
          },
        },
        'request': {
          'method': 'POST',
          // The upload host, not the API host: `files.create` with content is
          // an upload endpoint and the plain one silently creates an empty
          // file instead.
          'url': 'https://www.googleapis.com/upload/drive/v3/files',
          'query': {'uploadType': 'multipart', 'fields': 'id,name,webViewLink'},
          'multipart': {
            'metadata': {'name': '{name}'},
            'content': '{content}',
            'content_type': '{content_type}',
          },
        },
      },
      {
        'name': 'google_drive_delete_file',
        'description':
            'Permanently delete a Drive file Grid created. This does not go to '
            'the trash and cannot be undone — get the id from '
            'google_drive_list_files and confirm with the user first.',
        'params': {
          'file_id': {
            'type': 'string',
            'required': true,
            'description': 'The id from google_drive_list_files.',
          },
        },
        'request': {
          'method': 'DELETE',
          'url': 'https://www.googleapis.com/drive/v3/files/{file_id}',
        },
      },
    ],
  },
  'figma-api-app': {
    'auth': {
      'in': 'header',
      'name': 'Authorization',
      // Bearer, not `X-Figma-Token`. Figma accepts both headers but not
      // interchangeably: `X-Figma-Token` is for personal access tokens and an
      // OAuth token sent that way is rejected. Measured 2026-07-31 against
      // `GET /v1/me` with this account's own token — Bearer 200, X-Figma-Token
      // 403 "Invalid token".
      'format': 'Bearer {access_token}',
    },
    'tools': [
      {
        'name': 'figma_identity',
        'description':
            'Get the name, email and handle of the Figma account connected to '
            'Grid. Use this when the user asks which Figma account they are '
            'signed in as.',
        'params': <String, Object?>{},
        'request': {'method': 'GET', 'url': 'https://api.figma.com/v1/me'},
      },
      {
        'name': 'figma_get_file',
        'description':
            'Read the structure of a Figma file — its pages and the frames on '
            'them. Grid cannot browse or search Figma, so the user has to give '
            'a file link; the key is the part of the URL after /design/ or '
            '/file/. Start shallow and go deeper only if needed.',
        'params': {
          'file_key': {
            'type': 'string',
            'required': true,
            'description':
                'From the file URL: figma.com/design/<file_key>/Some-Name.',
          },
          'depth': {
            'type': 'integer',
            'required': true,
            'description':
                'How far down the tree to read. Use 1 for the list of pages, '
                '2 to also see the top-level frames on each page. A real '
                'design file is enormous, so never ask for more than you need.',
          },
        },
        'request': {
          'method': 'GET',
          'url': 'https://api.figma.com/v1/files/{file_key}',
          'query': {'depth': '{depth}'},
        },
      },
      {
        'name': 'figma_get_file_nodes',
        'description':
            'Read specific frames or layers from a Figma file, rather than the '
            'whole document. Prefer this over figma_get_file once you know '
            'which node you want.',
        'params': {
          'file_key': {
            'type': 'string',
            'required': true,
            'description':
                'From the file URL: figma.com/design/<file_key>/Some-Name.',
          },
          'node_ids': {
            'type': 'string',
            'required': true,
            'description':
                'Comma-separated node ids. A Figma link writes these with a '
                'hyphen (node-id=12-345) but the API wants a colon — send '
                '12:345.',
          },
          'depth': {
            'type': 'integer',
            'description':
                'How far below each node to read. Omit for the whole subtree, '
                'which can be very large.',
          },
        },
        'request': {
          'method': 'GET',
          'url': 'https://api.figma.com/v1/files/{file_key}/nodes',
          'query': {'ids': '{node_ids}', 'depth': '{depth}'},
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
