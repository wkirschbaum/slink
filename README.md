# Slink

A lightweight Slack bot toolkit for Elixir. One event-handling contract, two
interchangeable transports:

- **Socket Mode** (`Slink.SocketMode`) — dials out over a WebSocket, no public
  endpoint needed. Great for development and internal/behind-firewall apps.
- **Events API** (`Slink.EventsApi.Plug`) — a `Plug` that receives Slack's HTTP
  event callbacks. Slack's recommended transport for production and distribution.

Write your bot once; pick the transport per environment. Built on
[`Mint.WebSocket`](https://hex.pm/packages/mint_web_socket) and
[`Req`](https://hex.pm/packages/req), with JSON handled by Elixir's built-in
`JSON` module — no hand-rolled WebSocket protocol, no `Jason` dependency of our
own.

## Why not just use WebSockex / roll the protocol?

There is no official Slack SDK for Elixir (Bolt covers JS/Python/Java). But you
don't need to reimplement the WebSocket protocol to talk to Slack — `Mint.WebSocket`
already does that, correctly and maintained. Slink is the thin Slack-specific
layer on top: open the connection, verify/normalise payloads, acknowledge, and
dispatch. That's a few hundred lines you own, instead of a few thousand.

## Installation

```elixir
def deps do
  [
    {:slink, "~> 0.1"}
  ]
end
```

Requires Elixir ~> 1.19 (built-in `JSON`, refined compiler type warnings).

## Define a bot

```elixir
defmodule MyBot do
  use Slink

  @impl true
  def handle_event(%Slink.Event{type: "app_mention", payload: event}, context) do
    send_message(context, event["channel"], "hi <@#{event["user"]}> 👋")
    :ok
  end

  def handle_event(_event, _context), do: :ok
end
```

Handlers are **stateless**: to respond, call `send_message(context, channel, text)`
(imported by `use Slink`). It uses the `bot_token` from the context and routes
through a **per-channel rate limiter** so you never exceed Slack's ~1 msg/sec/
channel limit. For other Web API calls use `Slink.API` directly.

Both transports acknowledge the event to Slack *before* your handler runs and
dispatch it off-process, so a slow handler never blows Slack's 3-second ACK
window.

## Quickstart — connect to Slack in 5 minutes

Socket Mode needs **no public URL, no ngrok, no webhooks** — the bot dials out
to Slack. This is the fastest way to see it work.

### 1. Create the Slack app

1. Go to **https://api.slack.com/apps** → **Create New App** → **From a manifest**.
2. Pick your workspace.
3. Paste the contents of [`manifest.json`](manifest.json) (shipped in this repo) → **Next** → **Create**.

That's all your scopes, event subscriptions, and Socket Mode configured in one shot.

> **Name your bot.** The name is entirely yours — `slink` (the library) never
> hardcodes it, it runs purely off tokens. Before creating, edit these fields in
> `manifest.json` (and use your name in place of `@slink` below):
>
> | Field | Controls |
> |---|---|
> | `display_information.name` | the app's name in Slack's directory |
> | `features.bot_user.display_name` | the bot's @handle (what members `@mention`) |
> | `features.slash_commands[].command` | the slash command, e.g. `/yourbot` |

### 2. Grab two tokens

1. **Bot token** — left sidebar → **OAuth & Permissions** → **Install to Workspace** →
   **Allow** → copy the **Bot User OAuth Token** (starts with `xoxb-`).
2. **App token** — left sidebar → **Basic Information** → scroll to **App-Level Tokens** →
   **Generate Token and Scopes** → add the `connections:write` scope → **Generate** →
   copy the token (starts with `xapp-`).

### 3. Export them

```bash
export SLACK_BOT_TOKEN=xoxb-your-bot-token
export SLACK_APP_TOKEN=xapp-your-app-token
```

### 4. Run your bot

Add it to your application's supervision tree:

```elixir
children = [
  {Slink.SocketMode,
   module: MyBot,
   app_token: System.fetch_env!("SLACK_APP_TOKEN"),
   bot_token: System.fetch_env!("SLACK_BOT_TOKEN")}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

…or try it right now in IEx, no app needed:

```bash
iex -S mix
```
```elixir
{:ok, _} =
  Slink.SocketMode.start_link(
    module: Slink.ExampleBot,
    app_token: System.fetch_env!("SLACK_APP_TOKEN"),
    bot_token: System.fetch_env!("SLACK_BOT_TOKEN")
  )
```

### 5. Say hi

In Slack, invite the bot to a channel with `/invite @slink`, then mention it:
**`@slink hello`** — it replies 👋. Done.

> Want the bot to auto-join channels on boot? Pass `join: ["C0123456789"]` to
> `Slink.SocketMode`. Tune the outbound rate limit with
> `config :slink, :rate_interval_ms, 1_000`.

## Going to production — Events API (HTTP)

For production Slack recommends HTTP over Socket Mode (see the table below).
You'll need a public HTTPS endpoint. Run the plug with Bandit:

```elixir
Bandit.start_link(
  plug: {Slink.EventsApi.Plug,
         module: MyBot,
         signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
         bot_token: System.fetch_env!("SLACK_BOT_TOKEN")},
  port: 4000
)
```

…or mount it in an existing Plug/Phoenix router:

```elixir
forward "/slack/events", to: Slink.EventsApi.Plug,
  init_opts: [module: MyBot,
              signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
              bot_token: System.fetch_env!("SLACK_BOT_TOKEN")]
```

Then in the app's manifest/settings: set `"socket_mode_enabled": false`, add your
public URL as the **Request URL** under **Event Subscriptions**
(`https://your-host/slack/events`), and copy the **Signing Secret** from
**Basic Information** into `SLACK_SIGNING_SECRET`. Slink answers Slack's
`url_verification` handshake and verifies every request's signature automatically.

The same `MyBot` works unchanged across both transports.

## Transport choice, per Slack's own guidance

| | Socket Mode | Events API (HTTP) |
|---|---|---|
| Public URL required | No | Yes |
| Slack recommends for | development, internal, behind-firewall | **production**, reliability, scale |
| Marketplace / distributed apps | ✗ not allowed | ✓ required |
| Concurrency | capped at 10 connections/app | scales horizontally |

## Development

```bash
mix deps.get
mix test
```

## License

MIT — see [LICENSE](LICENSE).
