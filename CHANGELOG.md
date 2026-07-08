# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **Handler helpers** (imported by `use Slink`): `send_message/3,4`, `reply/3,4`,
  `reply_in_channel/3,4`, and `in_thread?/1`.
- **Per-channel outbound rate limiting** (`Slink.Rate`) to stay within Slack's
  ~1 message/sec/channel limit. Tunable via `config :slink, :rate_interval_ms`.
- **Web API client** (`Slink.API`) built on `Req`.
- `Slink.enabled?/1` to conditionally start a bot from config.
- A shippable app manifest (`manifest.json`) and a runnable `Slink.ExampleBot`.

[0.1.0]: https://github.com/wkirschbaum/slink/releases/tag/v0.1.0
