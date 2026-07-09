# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.1]: https://github.com/wkirschbaum/slink/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/wkirschbaum/slink/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/wkirschbaum/slink/releases/tag/v0.1.0
