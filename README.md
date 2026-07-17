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

## Why not `slack`, `slack_elixir`, or raw WebSockex?

There is no official Slack SDK for Elixir (Bolt covers JS/Python/Java), and the
existing options each leave a gap:

- **[`slack`](https://hex.pm/packages/slack)** (Elixir-Slack) is built on Slack's
  **RTM API**, which Slack has deprecated — it no longer works for new apps or bots.
- **[`slack_elixir`](https://hex.pm/packages/slack_elixir)** is a solid, modern
  client but **Socket Mode only** — there's no HTTP Events API transport, which
  Slack requires for Marketplace/distributed apps and recommends for production.
  Slink gives you both behind one handler contract.
- **Rolling your own on WebSockex/Mint** means reimplementing envelopes, ACKs,
  reconnection, and signature verification yourself. You don't need to — Slink is
  the thin Slack-specific layer on top of the maintained `Mint.WebSocket`: a few
  hundred lines you own, not a few thousand.

## Installation

```elixir
def deps do
  [
    {:slink, "~> 0.6"}
  ]
end
```

Requires Elixir ~> 1.19 (built-in `JSON` module, refined compiler type warnings).

## Define a bot

```elixir
defmodule MyBot do
  use Slink
  alias Slink.Event

  @impl true
  def handle_event(%Slink.Event{type: :app_mention} = event, context) do
    # Reply to what triggered us — threaded if it was in a thread, else inline.
    reply(context, "hi <@#{Event.user(event)}> 👋")
  end

  def handle_event(_event, _context), do: :ok
end
```

Handlers are **stateless**. Known Slack event types arrive as **atoms**
(`:app_mention`, `:message`, …); unknown ones stay strings. To respond, call
`reply(context, text, opts)` (imported by `use Slink`) — the channel and thread
come from the event carried in the `context`, `opts[:to]` picks placement
(`:auto`, `:thread`, `:channel`), and extra keys like `blocks:` ride along for
rich replies. `reply/3` returns `:ok`, so a clause can end with it. You can also
just **return** `{:reply, text}` (or `{:reply, text, opts}`) and slink sends it.
Replies route through a **per-channel rate limiter** (Slack's ~1 msg/sec/channel).
For other Web API calls use `Slink.API` directly.

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

## Beyond messages — slash commands, buttons & modals

The same `handle_event/2` handles slash commands, button clicks, and modals —
match on the event `type` and respond the way you always do. `Slink.BlockKit`
builds the block maps without a DSL:

```elixir
def handle_event(%Event{type: :block_actions} = event, context) do
  update_original(context, "Deploying #{Event.action_value(event)} 🚀")
end
```

→ **[Slash commands, buttons & modals](guides/interactivity.md)** — the full
tour, including modals, Block Kit builders, and how replies route. For
chaining helpers with `with`, see **[Composing helpers](guides/composing.md)**.

## AI apps — assistant threads & streamed replies

Assistant events normalise like any other; `set_status/2` shows "is
thinking…", and `stream_reply/3` renders an LLM token stream as one live,
progressively-updating message — degrading to a plain reply where streaming
isn't enabled:

```elixir
def handle_event(%Event{type: :message} = event, context) do
  set_status(context, "is thinking…")
  stream_reply(context, MyLLM.stream(Event.text(event)))
end
```

→ **[AI apps](guides/ai-apps.md)** — assistant threads, suggested prompts,
streaming semantics, scopes.

## Testing your bot

`Slink.Testing` runs a handler against realistic fixtures with every Slack
call captured — offline and synchronous; `mix slink.smoke` live-checks a real
token and workspace (including whether AI streaming is enabled):

```elixir
run = run(MyBot, event(:app_mention, text: "<@U1BOT> hi"))
assert [{"chat.postMessage", %{text: "hi" <> _}}] = run.calls
```

→ **[Testing your bot](guides/testing.md)**

## Going to production

Run the Events API plug (standalone Bandit or mounted in Phoenix), or stay on
Socket Mode with `connections: 2` for high availability. Signature
verification, ACK windows, retries, rate limiting, and secrets hygiene are
handled; telemetry and the operational knobs are documented alongside.

→ **[Going to production](guides/production.md)**

## Serving many workspaces

Both transports route a per-workspace token; `Slink.OAuth` +
`Slink.OAuth.Plug` handle the "Add to Slack" consent flow and code exchange —
you own only the token store.

→ **[Serving many workspaces](guides/multi-workspace.md)**

## Transport choice, per Slack's own guidance

| | Socket Mode | Events API (HTTP) |
|---|---|---|
| Public URL required | No | Yes |
| Slack recommends for | development, internal, behind-firewall | **production**, reliability, scale |
| Marketplace / distributed apps | ✗ not allowed | ✓ required |
| Concurrency | capped at 10 connections/app | scales horizontally |

## Roadmap

Planned, non-blocking capability work lives in [ROADMAP.md](ROADMAP.md).

## Development

```bash
mix deps.get
mix test
```

## License

MIT — see [LICENSE](LICENSE).
