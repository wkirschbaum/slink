# Going to production

Slack recommends the Events API (HTTP) for production and requires it for
Marketplace/distributed apps; Socket Mode remains great for development,
internal tools, and behind-firewall deployments. The same bot module works on
both — this guide covers hardening either.

## Events API (HTTP)

You need a public HTTPS endpoint. Standalone with Bandit:

```elixir
children = [
  {Bandit,
   plug: {Slink.EventsApi.Plug,
          module: MyBot,
          signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
          bot_token: System.fetch_env!("SLACK_BOT_TOKEN")},
   port: 4000}
]
```

Or mounted in Phoenix — two pitfalls, both detailed in
`Slink.EventsApi.Plug`'s docs:

1. **`forward` options are evaluated at compile time** in production — pass
   0-arity functions for secrets, not `System.fetch_env!/1` literals.
2. **The raw body must still be readable** for signature verification — mount
   the plug *before* `Plug.Parsers` in `endpoint.ex`, or run it standalone.

Point the app's **Event Subscriptions**, **Interactivity**, and **Slash
Commands** Request URLs at the endpoint. Slink verifies every request's
signature (fail-closed), answers `url_verification` and `ssl_check`, ACKs
within Slack's window, and dispatches handlers off-process.

## Socket Mode, highly available

Staying on Socket Mode in production? Hold two connections open so a drop
never loses events — Slack load-balances deliveries across them and Slink
dedups the overlap:

```elixir
{Slink.SocketMode, module: MyBot, connections: 2, app_token: ..., bot_token: ...}
```

Slack allows up to 10 connections per app. Reconnects back off exponentially
with jitter; an idle watchdog catches silently-dead connections
(`:idle_timeout_ms`).

## Operational knobs

| Config (`config :slink, ...`) | Default | What it does |
|---|---|---|
| `:rate_interval_ms` | `1_000` | minimum gap between sends per channel |
| `:rate_max_queue` | `1_000` | per-channel queue cap (oldest dropped past it) |
| `:rate_idle_stop_ms` | `600_000` | idle channel workers stop themselves |
| `:max_handler_tasks` | `:infinity` | opt-in cap on concurrent handlers; past it, events are shed with an error log |
| `:ack_timeout_ms` | `2_500` | bound on a synchronous `view_submission` handler |
| `:dedup` / `:dedup_ttl_ms` | `true` / 11 min | retried-delivery dedup and its memory window |

## Telemetry

Attach to these for logging or metrics; all carry
`%{system_time: System.system_time()}` as the measurement:

| Event | Metadata | When |
|---|---|---|
| `[:slink, :event, :received]` | `%{type:, transport:, module:}` | an event arrives, before dispatch |
| `[:slink, :socket, :connected]` | `%{module:}` | a Socket Mode handshake completes |
| `[:slink, :socket, :disconnected]` | `%{module:}` | a live Socket Mode connection drops |

## Secrets hygiene

Tokens never reach logs: transports and rate workers redact them from crash
reports (`format_status`), the handler context excludes the token from
inspects, and resolver/OAuth-callback failures log only the exception *kind*
(a `KeyError` from a token store would otherwise print the whole store).
