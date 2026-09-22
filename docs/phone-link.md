# The phone link

How Grid on a phone finds Grid on a computer, and the one thing that has to be
set up outside this repo for it to work.

It replaces the relay that used to sit in the middle: nothing is run by anybody,
no address is typed, and the only thing carried between the two devices is a
twenty-character code. Decided in `autonomous-grid/docs/adr/0045-*.md`; this file
is what the code actually does and what an operator has to publish.

## The shape of it

```
Desktop — Settings ▸ Phone ▸ Turn on sharing
  1. LocalPairingCell binds 127.0.0.1:<random>          nothing reachable yet
  2. cloudflared tunnel --url http://127.0.0.1:<port>   wss://<random>.trycloudflare.com
  3. for each paired phone:
       PATCH grid_phone/<docId>  { blob: sealed(cellUrl, hostId, hostKey, name) }

Phone — type the code
  1. GET grid_phone/<docId>  ->  open with the key the code derives
  2. dial <cellUrl>/v1/connect/<relayHostId>
  3. X25519 + HKDF, and require the key the record promised
  4. send the code, sealed, and be recognised
```

Three facts do the work:

- **The code is the whole credential.** 20 characters of Crockford base32 = 100
  bits, generated per phone. It derives the document's name and the key that
  opens it, under two different domains so the name — which travels in a URL —
  says nothing about the key.
- **The locator holds one address and nothing else.** No chats, no files. That is
  what keeps it inside a free tier shared with other apps, and it is a rule, not
  a habit: one open chat polling for new messages would spend a day's read quota
  in an afternoon.
- **A poisoned record is a phone that cannot connect, never a phone that connects
  to the wrong computer.** The record carries the computer's public key and the
  phone requires the socket to prove it holds the private half. Somebody who
  could write the document could only take the link down, which on the phone is
  indistinguishable from a computer that is asleep — a state the app already has
  a sentence for.

## What has to exist on Firebase

The locator is Firestore over REST — no SDK, no `google-services.json`, no native
build change on either app. It lives in the project the GroupMe apps already run
(`me-truyen-chu`), in Grid's own collection, and needs two things switched on
there:

1. **Authentication ▸ Sign-in method ▸ Anonymous ▸ Enable.** The rules demand a
   signed-in caller so that a stranger cannot spray the collection with REST
   calls; the sign-in is anonymous because there is no account here to sign in
   to. Grid signs in once per launch and reuses the session.
2. **Firestore ▸ Rules**, with this block added to whatever is already there:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // Grid's phone link. One document per paired phone, named by a hash of that
    // phone's code — so a document nobody can name is a document nobody reads.
    match /grid_phone/{syncId} {
      // Anonymous is enough: who owns a document is decided by the 100-bit code
      // that derives its name, never by an account.
      allow read: if request.auth != null && syncId.size() == 32;

      allow create, update: if request.auth != null
        && syncId.size() == 32
        // Two fields, and nothing else may be added.
        && request.resource.data.keys().hasOnly(['blob', 'updatedAt'])
        && request.resource.data.blob is string
        // Far under Firestore's 1 MiB ceiling: a record is a few hundred bytes,
        // so anything near this is a mistake or an attempt to fill the project.
        && request.resource.data.blob.size() < 8192;

      // A revoked phone's document is erased, and a delete carries no data to
      // check — so it gets its own line rather than failing the one above.
      allow delete: if request.auth != null && syncId.size() == 32;
    }
  }
}
```

`syncId.size() == 32` is the length of a `docId`, which is 32 hex characters of a
SHA-256. It has nothing to do with the length of the code a person types.

⚠️ **Until those rules are published, every write answers 403** and the app says
so in as many words, naming this file. That is the one failure here that is not
something a user can act on.

⚠️ **The `apiKey` in `locator_project.dart` is public and is not a secret.** It
ships inside every client that talks to the project and names it rather than
authorising anything. What keeps a computer's address private is the rules plus a
code nobody else holds.

⚠️ **The quota is shared with four shipped apps** — 50k reads and 20k writes per
day is a *project* ceiling. Grid spends one write per phone per address change
(a few a day) and one read per phone per connection. Moving anything else here
would be an outage for the other apps as much as for this one.

## What is deliberately missing

- **Grid does not install `cloudflared`.** The screen says what is missing and
  links Cloudflare's own page. Installing software because somebody opened a
  settings screen is not a decision this app makes.
- **A quick tunnel has no uptime guarantee**, by Cloudflare's own first line of
  output. The address changes every time it opens and it can be withdrawn at any
  moment — the controller notices, opens another, and republishes. A named tunnel
  is the upgrade path and changes one string, because nothing here assumes the
  address is stable.
- **`pairing_relay/` in the CLI repo is no longer in this path at all.** It stays
  there as a reference implementation of the route a phone dials; the desktop now
  serves that route itself.
