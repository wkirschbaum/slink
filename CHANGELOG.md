# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2026-07-17

Quality-of-life helpers for the most common bot patterns: DMs, ephemeral
replies, updating a clicked message, and knowing who the bot is.

### Added

- **`send_dm/4`** (imported by `use Slink`) — DM a user in one call:
  `conversations.open` + a rate-limited post. Also `Slink.API.open_dm/2`.
- **`reply(context, text, to: :ephemeral)`** — an only-the-invoker reply for
  *any* event kind: interactions and slash commands go through their
  `response_url`; plain events (a mention, a message) use `chat.postEphemeral`.
- **`update_original/3`** (imported) — replace the message an interaction came
  from via its `response_url` (`replace_original: true`): the canonical
  "button click updates its own message" pattern, and it works on ephemeral
  messages and in channels the bot isn't a member of.
- **Interactions without a channel no longer make `reply/3` raise** — a click
  on an ephemeral message, or in a channel the bot isn't in, falls back to the
  interaction's `response_url` (ephemeral by default, `to: :channel` for
  everyone) instead of failing.
- **Bot self-identity.** `context.bot_user_id` carries the bot's own user id,
  discovered via `auth.test` and cached per token by the new `Slink.Identity`
  (async prewarm — never blocks a transport; `nil` until the one-off lookup
  lands). Powers the imported **`mentions_me?/1`** — "am I mentioned in this
  message?" for events that aren't an `:app_mention`.
- **New `Slink.API` wrappers**: `schedule_message/5` (chat.scheduleMessage),
  `join_channel/2` (conversations.join), `history/3` (conversations.history,
  single page), `auth_test/1`, `open_dm/2`.

### Documentation

- ROADMAP: added a public testing module, one-call file uploads, Web API
  pagination streams, Block Kit builder functions, and AI-assistant app
  support (assistant events, status, streamed replies).

## [0.5.1] - 2026-07-17

Bug-hunt pass over the whole library (three independent review lenses:
OTP/concurrency, HTTP/security, Slack protocol semantics), plus routine
dependency updates.

### Security

- **A failing token/secret resolver no longer `inspect`s its exception into the
  log.** The documented multi-workspace pattern (`Map.fetch!(tokens, team_id)`)
  raises a `KeyError` whose `term` is the whole token map on an unknown team —
  logging the inspected exception printed every workspace's bot token. Only the
  failure's kind (e.g. `KeyError`) is logged now.

### Fixed

- **`Slink.Event.from_bot?/1` recognises the bot's own `message_changed`
  events.** Slack nests the real message (and its `bot_id`) under `"message"`
  for that subtype, so an edit or link unfurl of the bot's own post slipped past
  the auto-reply loop protection.
- **Slack's `ssl_check` probe no longer dispatches a phantom slash command.**
  The form-encoded `ssl_check=1` health probe of a slash-command URL is answered
  `200` directly instead of reaching handlers as a `:slash_commands` event with
  a `nil` command.
- **Exits are contained like raises on the crash-safety paths.** The Socket Mode
  message path and the rate worker's send loop rescued exceptions but not exits;
  a Finch pool-checkout timeout (a slow Slack — exactly when the queue is
  longest) *exits*, which crashed the rate worker and dropped its whole queue,
  and a task-supervisor blip could take down the transport.
- **`Slink.SocketMode` with `name: nil` gets a unique child id**, so several
  unregistered clients coexist under one static supervisor, as the docs promise.

### Added

- `tokens_revoked` and `app_uninstalled` are known event types (atoms), since a
  multi-workspace app typically handles them to prune its token store.

### Documentation

- Telemetry events (`[:slink, :event, :received]`, `[:slink, :socket,
  :connected]`, `[:slink, :socket, :disconnected]`) are now documented in the
  README.
- README install snippet tracks the current version (`~> 0.5`).
- `reply/3`'s no-channel error explains global shortcuts, not just modals; the
  `working/3` docs note the reaction can be left behind on a mid-work shutdown.

## [0.5.0] - 2026-07-09

Multi-workspace support: one bot module can now serve many workspaces over
either transport, routing a per-workspace token per request. Plus fixes from a
deep review of the new code.

### Added

- **Multi-workspace routing.** Slink was already token-per-call throughout; this
  makes serving several workspaces from one bot straightforward:
    - `Slink.Event.team_id/1` returns the workspace (team) id for any payload
      shape (event callback, interaction, slash command; both transports).
    - `Slink.EventsApi.Plug`'s `:bot_token` now also accepts a **1-arity
      function**, called with the event's team id — the seam for looking a token
      up from your own per-team store. String and 0-arity forms are unchanged.
      The signing secret stays a single value (it's per-app, not per-install).
    - `Slink.SocketMode` documents running one client per workspace, and now
      defines `child_spec/1` keyed on `:name` so several clients coexist under
      one supervisor.
  Acquiring/storing per-team tokens (the OAuth install flow) remains yours to
  own — see the roadmap.

### Fixed

- **A token/secret resolver that exits no longer 500s the request.** A 1-arity
  `:bot_token` (or `:signing_secret`) resolver backed by a token store `exit`s —
  not raises — on a `GenServer.call` timeout, which `rescue` alone didn't catch.
  `Slink.EventsApi.Plug` now also traps exits/throws and degrades to unset, as
  its never-500 contract promises.
- **`Slink.SocketMode.child_spec/1`** derives its `:id` from `:name`, so the
  documented one-client-per-workspace pattern boots instead of failing with
  `:duplicate_child_name` on the default id.

### Documentation

- Corrected `open_modal/2`: the opened view's id is for `update_view/3`;
  `push_view/3` takes a fresh `trigger_id` from a later in-modal interaction.
- `Slink.Dedup` documents that dedup is node-local (per-instance).
- Fixed `mix docs` warnings (doc references to the hidden Dispatcher module).

## [0.4.0] - 2026-07-09

A review-hardening release: closes the last token-to-logs path, removes a
connection crash-loop, and tightens the helper API for predictability. One small
breaking rename.

### Security

- **A bot token could reach crash logs via `Slink.Context`.** The context is
  handed to your `handle_event/2`, so a raising handler (e.g. a bot with no
  catch-all clause hitting a `FunctionClauseError`) had OTP print the context —
  token included — as a blamed argument. `Slink.Context` now derives an `Inspect`
  that omits `:bot_token`, closing the one leak the transports' `format_status/1`
  didn't already cover.

### Fixed

- **A raising `open_connection` no longer crash-loops the Socket Mode client.**
  With a missing/`nil` app token `Req` *raises* rather than returning an error;
  `connect/1` runs in `handle_continue`/`handle_info`, so the unrescued raise
  crashed the GenServer before its backoff — escalating into a supervisor restart
  loop that could take the host app down. `connect/1` now contains any raise/exit
  and schedules a backed-off retry, as its contract always promised.
- **`Slink.API.open_connection/1`** degrades a malformed `ok: true` response with
  no `"url"` to `{:error, {:no_url, body}}` instead of raising `CaseClauseError`.
- **`send_message/4` accepts a keyword list *or* a map** for opts, matching
  `reply/3` — `send_message(ctx, ch, "hi", blocks: [...])` previously raised
  `BadMapError`.
- **An invalid `to:` raises a clear `ArgumentError`** naming the allowed values,
  instead of a cryptic `FunctionClauseError` (message replies: `:auto` / `:thread`
  / `:channel`) or silently collapsing to ephemeral (slash replies: `:ephemeral`
  / `:channel`).
- **A signing-secret/bot-token resolver that raises** (e.g. `System.fetch_env!`
  on an unset var) is treated as unset — the request fails closed (401) instead
  of 500ing.
- **A `view_submission` handler that returns `{:reply, …}`** (silently dropped —
  a modal submit answers only with `{:ack, map}`) now logs a warning, so the
  no-op is visible.

### Changed

- **Breaking: `Event.mention?/1` is renamed to `Event.app_mention?/1`**, to
  disambiguate it from `mentions?/2` ("is this an `app_mention` event" vs "is a
  given user mentioned in the text"). Rename any call sites.
- **`in_thread?/1` also accepts a `context`** (not just an `Event`), consistent
  with the other `use Slink` helpers.

## [0.3.2] - 2026-07-09

### Documentation

- **Clarified the `handle_event/2` return contract.** A handler returns `:ok`
  (or anything that isn't `{:reply, …}` / `{:ack, …}`) when there's nothing to
  reply — no ceremony. `open_modal/2` keeps returning `{:ok, response} |
  {:error, reason}` (the standard shape for a call that returns data and can
  fail; `response["view"]["id"]` is what you pass to `update_view/3` /
  `push_view/3`), and a handler can simply end with it — the dispatcher treats
  its non-`{:reply, …}` return as "no reply", so no trailing `:ok` is needed.
  The docs previously implied one was required.
- **README** now shows replying with a button (Block Kit `blocks` on a reply)
  and handling the click.

## [0.3.1] - 2026-07-09

### Security

- **A bot token could still reach crash reports via the last-message field.**
  0.3.0 redacted the rate-limit worker's *state*, but OTP also prints the last
  message a process handled, and an `{:enqueue, {token, …}}` cast carries the
  token — so a worker crashing mid-cast (e.g. a `send_fun` that `exit`s, which
  `pump/1`'s `rescue` doesn't catch) still logged it. `Slink.Rate.Channel`'s
  `format_status/1` now redacts the `:message` too.

## [0.3.0] - 2026-07-09

Deep-review release: connection-lifecycle hardening for Socket Mode, dedup
correctness, resource bounds, and Phoenix deployment fixes.

### Added

- **Socket Mode liveness watchdog** (`:idle_timeout_ms`, default 2 minutes).
  A connection that dies without a close — NAT timeout, network partition —
  previously left the client believing it was connected *forever*: the bot went
  permanently deaf until the process was restarted. Slack pings every few
  seconds, so silence now triggers a reconnect. Pass `:infinity` to disable.
- **The Events API plug accepts `signing_secret`/`bot_token` as 0-arity
  functions**, resolved per request. Phoenix's `forward` evaluates init options
  at compile time in production, so a literal `System.fetch_env!/1` in the
  router read the *build* machine's env (or failed the build). New *Mounting in
  Phoenix* docs also cover the `Plug.Parsers` raw-body pitfall (mounted after
  parsers, signature verification always 401s).
- `config :slink, :rate_idle_stop_ms, 600_000` — an idle channel rate-limit
  worker now stops itself (default 10 min). Previously every channel ever
  posted to kept a worker process alive for the node's lifetime.

### Security

- **Bot tokens no longer appear in crash reports.** OTP prints a GenServer's
  full state when it terminates abnormally (and in `:sys.get_status`); the
  Socket Mode client's state and every queued rate-limiter request carry the
  bot token, so any crash wrote tokens to logs. Both now implement
  `format_status/1` and redact them.
- **Signature verification fails closed on a misconfigured signing secret.**
  A secret that resolves to `nil`, `""`, or a non-string (e.g. a function
  reading a missing env var) now rejects with 401 instead of crashing into a
  500 — and an empty secret is never accepted, since an empty-key HMAC is
  computable by anyone.

### Fixed

- **Event dedup now covers Slack's real retry schedule.** Slack retries a
  failed delivery immediately, after ~1 minute, and after ~5 minutes; the old
  60s default TTL only caught the first retry, so later retries double-fired
  handlers. Default `:dedup_ttl_ms` is now 11 minutes.
- **Event dedup is keyed per handler module.** Two bots in one VM (two Slack
  apps receiving the same workspace event, which carries the same `event_id`)
  shared one dedup namespace — whichever dispatched first silently swallowed
  the other's delivery.
- **A duplicate reconnect timer no longer opens a second connection.** Slack
  sends `disconnect` and then closes the socket; when both arrived in one batch
  each scheduled a reconnect, and the second `:connect` opened a parallel
  connection while leaking the first. A `:connect` while connected is now
  ignored.
- **Stale bytes can no longer leak across reconnects.** A reconnect firing
  mid-batch could buffer trailing frame bytes from the old connection and later
  decode them with the *new* connection's WebSocket state, corrupting its
  framing. The buffer is now cleared when a new connection starts.
- **Reconnect backoff resets on Slack's `hello`, not on the WebSocket
  handshake** — an accept-then-immediately-disconnect loop (e.g. too many
  connections) now backs off instead of retrying at full speed forever.
- The `url_verification` challenge is echoed only when it's a string.

## [0.2.2] - 2026-07-09

Robustness release: no user action, handler return value, or malformed Slack
frame can take a transport down.

### Fixed

- **A `view_submission` handler can no longer take down the transport.** When a
  handler returned an `{:ack, map}` whose payload wasn't JSON-encodable (e.g. it
  held a tuple), encoding the ACK frame raised inside the transport process — on
  Socket Mode this crashed the connection and the supervisor's restart re-read
  the same envelope, producing a crash-reconnect loop. The payload is now checked
  for encodability before the ACK frame is built; a non-encodable one is
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

[0.4.0]: https://github.com/wkirschbaum/slink/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/wkirschbaum/slink/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/wkirschbaum/slink/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/wkirschbaum/slink/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/wkirschbaum/slink/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/wkirschbaum/slink/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/wkirschbaum/slink/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/wkirschbaum/slink/releases/tag/v0.1.0
