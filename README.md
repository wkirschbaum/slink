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
    {:slink, "~> 0.8"}
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

The same `handle_event/2` handles slash commands and interactive components, over
either transport. Match on the event `type`; reply the same way you always do.

```elixir
def handle_event(%Event{type: :app_mention} = _event, context) do
  # Reply with a button: any reply can carry Block Kit `blocks`. `action_id`
  # identifies the button when it's clicked; `value` rides along with the click.
  reply(context, "Ready to deploy?",
    blocks: [
      %{
        type: "actions",
        elements: [
          %{
            type: "button",
            action_id: "deploy",
            text: %{type: "plain_text", text: "Deploy"},
            value: "prod"
          }
        ]
      }
    ]
  )
end

def handle_event(%Event{type: :block_actions} = event, context) do
  # The click arrives as its own event. update_original/3 swaps the message the
  # button is on ("click → the message becomes the result"); or reply/3 posts a
  # new one — to: :ephemeral answers only the clicker, and clicks on ephemeral
  # messages route through the interaction's response_url automatically.
  update_original(context, "Deploying #{Event.action_value(event)} 🚀")
end

def handle_event(%Event{type: :slash_commands} = event, context) do
  # Slash commands reply through their response_url — reply/3 handles that.
  # to: :ephemeral (default) shows only the invoker; to: :channel posts publicly.
  reply(context, "running `#{Event.text(event)}`…", to: :channel)
end

def handle_event(%Event{type: :shortcut} = _event, context) do
  # Open a modal. Uses the event's trigger_id (valid ~3s), so open promptly.
  # open_modal/2 returns {:ok, response} | {:error, reason}; a handler can just
  # end with it (a non-{:reply, _} return means "nothing to reply"). Match it
  # when you need response["view"]["id"] for a later update_view/3 / push_view/3.
  open_modal(context, my_view())
end

def handle_event(%Event{type: :view_submission} = event, _context) do
  # A modal submit. Return {:ack, map} to control the modal; this one runs
  # synchronously so keep it quick. Anything else closes the modal.
  case Event.view_values(event) do
    %{"email" => %{"input" => %{"value" => v}}} when v == "" ->
      {:ack, %{response_action: "errors", errors: %{"email" => "required"}}}

    _ ->
      :ok
  end
end
```

You have room to choose *how* to respond:

- **Return a value** — `:ok`, `{:reply, text}` / `{:reply, text, opts}`, or (for a
  modal submit) `{:ack, map}`. The simplest path.
- **Call a helper** — `reply/3` (routes to a thread, channel, ephemeral view, or
  `response_url` as the event and `to:` demand), `update_original/3`,
  `send_message/4`, `send_dm/4`, `open_modal/2`, `working/3`, `mentions_me?/1`.
- **Call the Web API directly** — `Slink.API` (`post_ephemeral/5`,
  `update_message/5`, `schedule_message/5`, `open_dm/2`, `upload_file/3`,
  `stream/3` for cursor pagination, `views.*`, `respond/2`, …) for anything
  the helpers don't cover.

The handler context also carries the bot's own identity: `context.bot_user_id`
(discovered via `auth.test`, cached) powers `mentions_me?/1` — "was I mentioned
in this thread message?" — without an `:app_mention` event.

The helpers are built to combine with `with` — consistent `:ok` /
`{:error, reason}` shapes, so a chain of actions short-circuits on the first
failure. See the [Composing helpers](guides/composing.md) guide.

Over the Events API, point the app's **Interactivity** and **Slash Commands**
Request URLs at the same endpoint as events; Slink decodes all three. Slack
retries deliveries it doesn't see ACKed — Slink drops the duplicates
(`Slink.Dedup`) so your handler fires once.

Block maps getting verbose? `Slink.BlockKit` has plain builder functions —
no DSL, they just return the maps:

```elixir
import Slink.BlockKit

reply(context, "Ready to deploy?",
  blocks: [
    section("*prod* is 3 commits behind — ship it?"),
    actions([button("Deploy", action_id: "deploy", value: "prod", style: "primary")])
  ])
```

## AI apps — assistant threads & streamed replies

Slink covers Slack's AI-app surface: the `:assistant_thread_started` /
`:assistant_thread_context_changed` events normalise like any other, and
handlers get `set_status/2` ("is thinking…") plus `stream_reply/3`, which
renders any enumerable of text chunks — an LLM token stream — as one live,
progressively-updating message:

```elixir
def handle_event(%Event{type: :message} = event, context) do
  set_status(context, "is thinking…")
  stream_reply(context, MyLLM.stream(Event.text(event)))
end
```

Chunks are batched under Slack's rate limits, and if the surface can't stream,
the reply degrades to a single message — it always arrives. Suggested prompts
and thread titles are on `Slink.API` (`set_suggested_prompts/5`,
`set_thread_title/4`). Requires the `assistant:write` scope and the Agents
toggle in the app config.

## Testing your bot

`Slink.Testing` makes handlers unit-testable without Slack: build a realistic
event fixture, run the handler, and assert on what it sent — synchronously,
nothing touches the network:

```elixir
defmodule MyBotTest do
  use ExUnit.Case, async: false
  import Slink.Testing

  test "greets a mention in its thread" do
    run = run(MyBot, event(:app_mention, text: "<@U1BOT> hi", thread_ts: "1.0"))

    assert [{"chat.postMessage", %{text: "hi" <> _, thread_ts: "1.0"}}] = run.calls
  end
end
```

Fixtures exist for mentions, messages, reactions, slash commands, button
clicks, modal submits and more — see `Slink.Testing.event/2`. Failure paths are
scriptable via the `:api` option.

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

…or mount it in an existing Plug/Phoenix router. Pass the secrets as functions —
Phoenix evaluates `forward` options at compile time in production — and mount it
where the raw body is still readable (before `Plug.Parsers`; see the
`Slink.EventsApi.Plug` docs):

```elixir
forward "/slack/events", to: Slink.EventsApi.Plug,
  init_opts: [module: MyBot,
              signing_secret: fn -> System.fetch_env!("SLACK_SIGNING_SECRET") end,
              bot_token: fn -> System.fetch_env!("SLACK_BOT_TOKEN") end]
```

Then in the app's manifest/settings: set `"socket_mode_enabled": false`, add your
public URL as the **Request URL** under **Event Subscriptions**
(`https://your-host/slack/events`), and copy the **Signing Secret** from
**Basic Information** into `SLACK_SIGNING_SECRET`. Slink answers Slack's
`url_verification` handshake and verifies every request's signature automatically.

The same `MyBot` works unchanged across both transports.

Staying on Socket Mode in production instead? Hold two connections open so a
drop never loses events — Slack load-balances across them and Slink dedups:

```elixir
{Slink.SocketMode, module: MyBot, connections: 2, app_token: ..., bot_token: ...}
```

## Serving many workspaces — the OAuth install flow

Both transports already route a per-workspace token (see *Multiple workspaces*
in the module docs). To *acquire* those tokens as workspaces install your app,
send installers to `Slink.OAuth.authorize_url/1` and mount `Slink.OAuth.Plug`
at the app's Redirect URL — it exchanges the returned code and hands the result
to your store:

```elixir
forward "/slack/oauth/callback", to: Slink.OAuth.Plug,
  init_opts: [
    client_id: "1234.5678",
    client_secret: fn -> System.fetch_env!("SLACK_CLIENT_SECRET") end,
    install: fn install -> MyApp.Installs.put(install.team_id, install.bot_token) end
  ]
```

Persistence stays yours: store `{team_id, bot_token}` however you like, and
hand it back per request via the `:bot_token` resolver. The `:install`
callback must return `:ok` — anything else (or a raise) answers the installer
with a 500 rather than claiming success.

## Transport choice, per Slack's own guidance

| | Socket Mode | Events API (HTTP) |
|---|---|---|
| Public URL required | No | Yes |
| Slack recommends for | development, internal, behind-firewall | **production**, reliability, scale |
| Marketplace / distributed apps | ✗ not allowed | ✓ required |
| Concurrency | capped at 10 connections/app | scales horizontally |

## Telemetry

Slink emits [`:telemetry`](https://hexdocs.pm/telemetry) events you can attach
to for logging or metrics. All carry `%{system_time: System.system_time()}` as
the measurement:

| Event | Metadata | When |
|---|---|---|
| `[:slink, :event, :received]` | `%{type:, transport:, module:}` | an event arrives, before dispatch |
| `[:slink, :socket, :connected]` | `%{module:}` | the Socket Mode WebSocket handshake completes |
| `[:slink, :socket, :disconnected]` | `%{module:}` | a live Socket Mode connection drops |

## Roadmap

Planned, non-blocking capability work lives in [ROADMAP.md](ROADMAP.md).

## Development

```bash
mix deps.get
mix test
```

## License

MIT — see [LICENSE](LICENSE).
