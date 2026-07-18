# Playground: a local fake Slack

`Slink.Playground` serves a Slack-like web UI on localhost so you can try your
bot without a workspace, tokens, or the Slack client. You type messages, run
slash commands, click buttons and submit modals in the browser; your bot
receives them as real events, and everything it does — posts, edits, threads,
ephemeral replies, reactions, modals, App Home, streamed replies — appears
live in the page. An **inspector** drawer at the bottom shows every raw
inbound envelope and outbound Web API call.

It sits between the other two halves of slink's testing story: faster and more
visual than `Slink.Testing`'s offline unit tests, and safer than pointing
`mix slink.smoke` at a real channel.

## Setup

The playground is compiled out of slink by default. Three steps, all dev-only:

```elixir
# config/dev.exs
config :slink, playground: true
```

```elixir
# mix.exs — Bandit is slink's optional HTTP server
{:bandit, "~> 1.12", only: :dev}
```

```elixir
# your dev supervision tree, typically instead of Slink.SocketMode
{Slink.Playground, module: MyBot, port: 4040}
```

Changing the flag changes slink's compile-time config, so Mix will ask you to
`mix deps.compile slink --force` once. Then open
[http://localhost:4040](http://localhost:4040).

## What a session looks like

- **Message the bot** — type in `#general` or the DM. `@slinkbot` autocompletes
  and becomes real `<@U0BOT>` mention markup. A mention in a channel delivers
  *both* a `:message` and an `:app_mention` event, exactly like Slack.
- **Slash commands** — type `/deploy prod` and hit Enter. The reply goes
  through a real `response_url` round trip, ephemeral by default.
- **Interactivity** — buttons and static selects in Block Kit messages
  dispatch `:block_actions` with the full message embedded; modals opened with
  `open_modal/2` render and submit through the real sync-ack path, so
  `{:ack, %{response_action: "errors", ...}}` shows validation errors inline.
- **App Home** — the sidebar's *slinkbot — Home* entry fires
  `:app_home_opened`; whatever you `Slink.API.publish_view/3` renders there.
- **Reactions** — react to any message (dispatches `:reaction_added`); the
  bot's own reactions show up too, so `working/3`'s ⏳ is visible.
- **Inspector** — expand any entry to see the exact envelope or API
  request/response. *redeliver* re-sends an inbound envelope with the same
  `event_id`, demonstrating that `Slink.Dedup` drops retries.

## How faithful is it?

The playground reuses the production pipeline at both ends. Inbound, it builds
Socket-Mode envelopes and runs them through the same normaliser and dispatcher
as the real transport. Outbound, it points `config :slink, :api_base_url` at
its own fake Web API, so calls travel through the real rate limiter and HTTP
client — including Slack's ~1 message/second/channel pacing (lower
`config :slink, :rate_interval_ms` if that slows your dev loop). Unknown API
methods answer a generic `ok: true` and are tagged *stubbed* in the inspector.

Deliberate deviations, in the interest of staying small:

- One human user (`U0DEV`) and one bot. Ephemeral messages are a styled flag
  rather than per-viewer visibility.
- `trigger_id` expiry (~3s) and `response_url` limits (5 uses / 30 min) are
  not enforced.
- The bot's own reactions don't dispatch `:reaction_added` events (avoids
  feedback loops with `working/3`).
- No HTTP 429 simulation; genuine rate-limit handling is covered by
  `Slink.API`'s tests.
- The `:api_base_url` takeover is VM-global and not restored on shutdown —
  don't run a real transport in the same VM (a warning is logged if a
  `Slink.SocketMode` client is running).

Because the fake workspace also answers reads (`conversations.history`,
`conversations.replies`, `conversations.info`), bots that look back at the
conversation work too.
