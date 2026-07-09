# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.2] - 2026-07-09

Robustness release: no user action, handler return value, or malformed Slack
frame can take a transport down.

### Fixed

- **A `view_submission` handler can no longer take down the transport.** When a
  handler returned an `{:ack, map}` whose payload wasn't JSON-encodable (e.g. it
  held a tuple), encoding the ACK frame raised inside the transport process — on
  Socket Mode this crashed the connection and the supervisor's restart re-read
  the same envelope, producing a crash-reconnect loop. The payload is now checked
  for encodability in `Slink.Dispatcher.ack_result/3`; a non-encodable one is
  logged and degrades to `%{}` (closing the modal), like a handler crash already
  does.
- **A malformed Slack frame can no longer crash the Socket Mode connection.**
  `Slink.Event` parsing and accessors used `get_in/2`, which raises when a value
  Slack normally nests as a map (a `channel`, `view`, `item`, or the envelope
  `payload` itself) arrives as a string, list, or null. Since `event_id/1` and
  event construction run in the socket process, that raise dropped the
  connection. All parsing and accessors are now total — a wrong-shaped payload
  yields `nil`/empty defaults instead of raising — and the socket wraps
  per-message handling as a final backstop. That backstop also no longer reverts
  a sent ACK's connection state: a dispatch that raised *after* the envelope was
  ACKed would otherwise unwind to the pre-ACK state and leave the socket on a
  stale Mint connection, so the post-ACK dispatch is contained on its own.
- **A bad reply body no longer crashes a channel's rate-limit worker.** If a
  handler's reply carried a body the Web API client couldn't encode, the raise
  killed the per-channel `Slink.Rate.Channel` worker and dropped everything else
  queued for that channel. The send is now wrapped so a raising call is logged
  and draining continues, and `Slink.Rate` tolerates a worker that fails to start
  rather than crashing the caller.
- **The Events API plug no longer 500s on a form body with invalid
  percent-encoding** — `URI.decode_query/1` raising now degrades to an empty
  payload.

## [0.2.1] - 2026-07-09

### Fixed

- **`reply/3` to a reaction event no longer crashes.** `reaction_added` /
  `reaction_removed` nest their target under `payload["item"]`, so
  `Event.channel/1`, `ts/1` now read it there — previously a reply to a reaction
  raised `ArgumentError` (no channel) and `working/3` was a no-op.

### Changed

- **`Event.command/1` unwraps Slack link markup to plain text.** A linkified
  address (`<mailto:a@b.com|a@b.com>`) now comes through as the bare `a@b.com`,
  and `<@U1|alice>` / `<#C1|general>` / `<https://x|label>` reduce to their
  name/url — so the addressed text reads as a human typed it. A bare `<@U1>`
  (e.g. the bot's own mention) still drops out.

## [0.2.0] - 2026-07-09

### Added

- **Slash commands, end to end.** Both transports now decode slash-command
  payloads (`application/x-www-form-urlencoded` over HTTP). `reply/3` routes by
  event kind — a channel post for messages and interactions, or the
  `response_url` for a slash command (`to: :ephemeral` default, or `:channel`) —
  and raises clearly when an event has no channel to reply to (e.g. a
  `view_submission`). New `Slink.Event` accessors: `command_name/1`,
  `response_url/1`, `trigger_id/1`.
- **Interactivity & modals.** Interactions are routed on their inner type
  (`:block_actions`, `:view_submission`, `:shortcut`, …). A `view_submission`
  handler may return `{:ack, map}` to control the modal (validation errors,
  update, push) — it runs synchronously so Slack gets the response in time.
  New helper `open_modal/2` (imported by `use Slink`) and
  `Slink.API.open_view/3`, `update_view/3`, `push_view/3`, `publish_view/3`
  (App Home). New `Slink.Event` accessors: `actions/1`, `action_id/1`,
  `action_value/1`, `callback_id/1`, `view/1`, `view_values/1`.
- **Event deduplication** (`Slink.Dedup`). Slack's retried deliveries (same
  `event_id`) dispatch only once. On by default; `config :slink, :dedup, false`
  to disable, `:dedup_ttl_ms` to tune. New `Slink.Event.event_id/1`,
  `retry?/1`, `retry_attempt/1`.
- **Wider Web API surface** (`Slink.API`): `update_message/5`,
  `delete_message/3`, `post_ephemeral/5`, `get_permalink/3`, `user_info/2`, and
  `respond/2` (post to a `response_url`). `call/3` now retries HTTP `429`s,
  honouring `Retry-After`.

## [0.1.0] - 2026-07-08

Initial release.

### Added

- **One event-handling contract, two transports.** Write a bot once against the
  `Slink` behaviour and run it over either transport unchanged.
  - `Slink.SocketMode` — dials out to Slack over a WebSocket
    (`Mint.WebSocket`), no public endpoint required. Opens the connection via
    `apps.connections.open`, auto-reconnects, and optionally auto-joins channels
    on boot (`:join`).
  - `Slink.EventsApi.Plug` — a `Plug` for Slack's HTTP event callbacks. Mount it
    in a Plug/Phoenix router or run it standalone with Bandit.
- **Request hardening (Events API):** HMAC-SHA256 signature verification against
  the raw body, constant-time comparison, timestamp-freshness (replay) window,
  request-body size cap, and automatic `url_verification` handshake.
- **Normalised events.** `Slink.Event` collapses Socket Mode envelopes and HTTP
  payloads into one shape; both transports acknowledge to Slack *before* your
  handler runs and dispatch off-process, so a slow handler never blows Slack's
  ~3s ACK window.
- **Handler helpers** (imported by `use Slink`): `send_message/3,4`, `reply/2,3`,
  `working/2,3`, and `in_thread?/1`.
- **Per-channel outbound rate limiting** (`Slink.Rate`) to stay within Slack's
  ~1 message/sec/channel limit. Tunable via `config :slink, :rate_interval_ms`.
- **Web API client** (`Slink.API`) built on `Req`.
- `Slink.enabled?/1` to conditionally start a bot from config.
- A shippable app manifest (`manifest.json`) and a runnable `Slink.ExampleBot`.

[0.2.2]: https://github.com/wkirschbaum/slink/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/wkirschbaum/slink/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/wkirschbaum/slink/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/wkirschbaum/slink/releases/tag/v0.1.0
