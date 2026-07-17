# AI apps — assistant threads & streamed replies

Slink covers Slack's AI-app surface end to end: the assistant events
normalise like any other, and two helpers do the heavy lifting — a status
line while you think, and a live streamed reply while you answer.

```elixir
defmodule MyAssistant do
  use Slink
  alias Slink.Event

  @impl true
  def handle_event(%Event{type: :assistant_thread_started} = event, context) do
    Slink.API.set_suggested_prompts(
      context.bot_token,
      Event.channel(event),
      Event.thread_ts(event),
      [%{title: "Summarise this channel", message: "summarise the recent activity"}]
    )

    :ok
  end

  def handle_event(%Event{type: :message, subtype: nil} = event, context) do
    set_status(context, "is thinking…")
    stream_reply(context, MyLLM.stream(Event.text(event)))
  end

  def handle_event(_event, _context), do: :ok
end
```

## What each piece does

- **`:assistant_thread_started` / `:assistant_thread_context_changed`** —
  fired when a user opens the assistant pane. `Event.channel/1`,
  `Event.user/1` and `Event.thread_ts/1` resolve from the nested
  `assistant_thread`, so the accessors just work. The user's messages then
  arrive as ordinary `:message` events in that DM.
- **`set_status/2`** — the "is thinking…" line under the thread. Pass `""` to
  clear; posting or streaming a reply clears it automatically.
- **`stream_reply/3`** — pass any enumerable of text chunks (an LLM token
  stream, a `Stream`, a list) and it renders as one live, progressively-
  updating message via `chat.startStream` / `appendStream` / `stopStream`.
  Chunks are batched (at most one append per `:flush_ms`, default 400ms) and
  sliced under Slack's 12k-per-append cap. Returns `{:ok, ts}`.
- **Thread titles** — `Slink.API.set_thread_title/4` names the conversation
  in the user's assistant history.

## Graceful degradation

If the surface can't stream — the feature isn't enabled for the app, or the
method errors — `stream_reply/3` **falls back to a single `chat.postMessage`**
with the full text. The reply always arrives; streaming is an enhancement.

Streaming into a *channel* (rather than the app's DM) additionally requires
`start: %{recipient_user_id: ..., recipient_team_id: ...}`.

## Requirements & verification

The assistant methods need the `assistant:write` scope and the **Agents**
toggle in the app configuration; streaming runs under `chat:write`.

To check a real workspace, run the live smoke test — its AI step reports
whether streaming is enabled without failing the run:

```bash
SLACK_BOT_TOKEN=xoxb-... mix slink.smoke C<your-test-channel>
```

For unit tests, `Slink.Testing` has assistant fixtures —
`event(:assistant_thread_started, ...)` — and `run/3` captures the
`startStream`/`appendStream`/`stopStream` calls; see the
[Testing your bot](testing.md) guide.
