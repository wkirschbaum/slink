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
