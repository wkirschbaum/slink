# Roadmap

Planned work, roughly in priority order. Nothing here is a bug — these are
capability decisions we've chosen to defer.

## OAuth install flow helper

Slink already routes per-workspace tokens (a `:bot_token` resolver over HTTP, one
client per workspace over Socket Mode — see the *Multiple workspaces* docs), but
you still have to *acquire* and store those per-team tokens yourself. A public
Marketplace app installs via OAuth: an "Add to Slack" redirect, then exchanging
the returned code with `oauth.v2.access` for the workspace's bot token. The plan:
a small optional plug/helper that handles the redirect + code exchange and hands
the resulting `{team_id, bot_token}` to a storage callback you provide — Slink
stays out of the persistence business, but the Slack round-trip is done for you.

## Socket Mode high availability (multiple connections)

Slink currently runs a single Socket Mode WebSocket. Slack recommends keeping
**2+ connections open per app** so that when one drops (or during Slack's own
rolling reconnects) another is already live and no events are missed — Slack
load-balances deliveries across the open sockets. The plan: let
`Slink.SocketMode` run N connections (e.g. `connections: 2`) under one
supervisor, sharing the dispatcher and dedup so a delivery seen on either socket
still fires the handler exactly once. The per-handler dedup already makes this
safe; this is additive and opt-in (default stays 1).

## A public testing story

Slink's own tests have nice machinery (a fake Slack WebSocket server, a fake Web
API, the `:rate_sender`/`:identity_fetch` seams) but bot *authors* get none of
it. The plan: a small `Slink.Testing` module — build a `Slink.Event` fixture
(`event(:app_mention, text: "deploy", channel: "C1")`), run it through the
dispatcher, and capture what the handler would have sent — so `handle_event/2`
is unit-testable without ever touching Slack.

## File uploads

Slack's current upload flow is the two-step `files.getUploadURLExternal` →
upload the bytes → `files.completeUploadExternal` dance. The plan: wrap it as a
single `upload_file` call on `Slink.API` (content or path, filename, target
channel), hiding the round-trips.

## Web API pagination

A lazy `Stream` over cursor-paginated methods (`conversations.history`,
`users.list`, …): `Slink.API.stream(token, method, params)` fetches pages on
demand, following `response_metadata.next_cursor` until exhausted, with rate
limiting handled. `Slink.API.history/3` covers a single page today; this makes
"read the whole channel" a one-liner.

## Block Kit ergonomics

Hand-writing block maps is the most verbose part of any bot. The plan: a tiny
optional builder of pure functions — `section("hi")`, `button("Deploy",
action_id: "deploy")`, `actions([...])` — that just return the maps Slack
expects. No DSL, no macros, fully mixable with hand-written maps.

## AI-assistant apps

Slack's assistant surface is where much new bot development happens: the
`assistant_thread_started` / `assistant_thread_context_changed` events, the
`assistant.threads.setStatus` / `setTitle` / `setSuggestedPrompts` methods, and
streaming token-by-token LLM replies into a message. Slink is well-positioned —
normalized events plus a `stream_reply(context, enumerable)` helper that
throttles updates through `Slink.Rate`. Verify the current method names against
Slack's docs when picking this up; the surface is still evolving.
