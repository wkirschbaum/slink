# Testing your bot

Two halves: `Slink.Testing` for fast, offline unit tests of your handlers,
and `mix slink.smoke` for a live check of a real token and workspace.

## Unit tests — `Slink.Testing`

Build a realistic event fixture, run the handler, assert on what it sent —
synchronously, nothing touches the network:

```elixir
defmodule MyBotTest do
  # run/3 swaps process-global test seams — keep these tests async: false.
  use ExUnit.Case, async: false
  import Slink.Testing

  test "greets a mention in its thread" do
    run = run(MyBot, event(:app_mention, text: "<@U1BOT> hi", thread_ts: "1.0"))

    assert [{"chat.postMessage", %{text: "hi" <> _, thread_ts: "1.0"}}] = run.calls
  end

  test "a slash command is answered ephemerally" do
    run = run(MyBot, event(:slash_command, command: "/deploy", text: "prod"))

    assert [%{response_type: "ephemeral"}] = run.responses
  end

  test "a missing scope degrades gracefully" do
    run =
      run(MyBot, event(:app_home_opened),
        api: fn
          "conversations.open", _params -> {:error, "missing_scope"}
          _method, _params -> {:ok, %{"ok" => true}}
        end)

    assert [{"conversations.open", _}, {"chat.postMessage", %{text: "dm failed" <> _}}] =
             run.calls
  end
end
```

What you get back is a `Slink.Testing.Run`:

- `result` — the handler's raw return value (a `{:reply, …}` is also
  *performed* and captured, exactly as the dispatcher would — including being
  dropped for a `view_submission`, as production drops it).
- `calls` — Web API calls in order, `{method, params}` tuples.
- `responses` — `response_url` posts (slash replies, `update_original/3`).

Fixtures exist for mentions, messages (including nested
`message_changed`/`message_deleted` shapes), reactions, slash commands,
button clicks, modal submits, shortcuts, App Home, and assistant threads —
all assembled through the production normaliser so shapes can't drift. See
`Slink.Testing.event/2` for every attribute. Failure paths are scriptable via
`:api` (which also receives `"response_url"` posts as a pseudo-method), and
`bot_user_id:` makes `mentions_me?/1` live.

## Live checks — `mix slink.smoke`

`auth.test`, but for everything Slink uses. Point it at a private testing
channel (invite the bot first); it posts a couple of test messages:

```bash
SLACK_BOT_TOKEN=xoxb-... mix slink.smoke C0123456789
```

Steps: identity (`auth.test`), a post, reactions (what `working/3` needs),
the `chat.startStream` trio — **informational**: it reports whether AI
streaming is enabled without failing the run — and a final `chat.update`.
Required failures exit non-zero, so it slots into a deploy pipeline.
