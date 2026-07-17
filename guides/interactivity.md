# Slash commands, buttons & modals

The same `handle_event/2` handles slash commands and interactive components,
over either transport. Match on the event `type`; respond the same way you
always do.

```elixir
defmodule MyBot do
  use Slink
  import Slink.BlockKit
  alias Slink.Event

  @impl true
  def handle_event(%Event{type: :app_mention} = _event, context) do
    # Any reply can carry Block Kit blocks. `action_id` identifies the button
    # when it's clicked; `value` rides along with the click.
    reply(context, "Ready to deploy?",
      blocks: [
        section("*prod* is 3 commits behind — ship it?"),
        actions([button("Deploy", action_id: "deploy", value: "prod", style: "primary")])
      ])
  end

  def handle_event(%Event{type: :block_actions} = event, context) do
    # The click arrives as its own event. update_original/3 swaps the message
    # the button is on ("click → the message becomes the result"); or reply/3
    # posts a new one — to: :ephemeral answers only the clicker, and clicks on
    # ephemeral messages route through the interaction's response_url.
    update_original(context, "Deploying #{Event.action_value(event)} 🚀")
  end

  def handle_event(%Event{type: :slash_commands} = event, context) do
    # Slash commands reply through their response_url — reply/3 handles that.
    # to: :ephemeral (default) shows only the invoker; to: :channel is public.
    reply(context, "running `#{Event.text(event)}`…", to: :channel)
  end

  def handle_event(%Event{type: :shortcut} = _event, context) do
    # Open a modal. Uses the event's trigger_id (valid ~3s), so open promptly.
    open_modal(context,
      modal("Deploy", [
        input("Environment", static_select("Choose…",
          [option("Production", "prod"), option("Staging", "staging")],
          action_id: "env"))
      ], submit: "Go", callback_id: "deploy"))
  end

  def handle_event(%Event{type: :view_submission} = event, _context) do
    # A modal submit. Return {:ack, map} to control the modal; this event runs
    # synchronously, so return promptly. Anything else closes the modal.
    case Event.view_values(event) do
      %{"env" => %{"env" => %{"selected_option" => nil}}} ->
        {:ack, %{response_action: "errors", errors: %{"env" => "pick one"}}}

      _ ->
        :ok
    end
  end

  def handle_event(_event, _context), do: :ok
end
```

## Ways to respond

- **Return a value** — `:ok`, `{:reply, text}` / `{:reply, text, opts}`, or
  (for a modal submit) `{:ack, map}`. The simplest path.
- **Call a helper** — `reply/3` (routes to a thread, channel, ephemeral view,
  or `response_url` as the event and `to:` demand), `update_original/3`,
  `send_message/4`, `send_dm/4`, `open_modal/2`, `working/3`,
  `mentions_me?/1`. See the [Composing helpers](composing.md) guide for how
  they chain.
- **Call the Web API directly** — `Slink.API` (`post_ephemeral/5`,
  `update_message/5`, `schedule_message/5`, `upload_file/3`, `stream/3`,
  `views.*`, `respond/2`, …) for anything the helpers don't cover.

## Block Kit without the boilerplate

`Slink.BlockKit` is a set of plain builder functions — no DSL, no macros. They
return exactly the maps Slack expects, so they mix freely with hand-written
ones: `section/2`, `header/1`, `divider/0`, `context/1`, `image/3`,
`actions/1`, `input/3`, `button/2`, `static_select/3`, `option/2`,
`plain_text_input/1`, `mrkdwn/1`/`plain_text/2`, and `modal/3` for
`open_modal/2`. Text defaults to `mrkdwn` where Slack allows it and
`plain_text` where Slack requires it.

## Wiring it up

Over the Events API, point the app's **Interactivity** and **Slash Commands**
Request URLs at the same endpoint as events; Slink decodes all three (and
answers Slack's periodic `ssl_check` probe itself). Over Socket Mode nothing
extra is needed. Slack retries deliveries it doesn't see ACKed — Slink drops
the duplicates so your handler fires once (`view_submission` is the exception:
its synchronous ack must answer every delivery).
