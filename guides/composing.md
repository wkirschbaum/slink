# Composing helpers

A handler often does more than one thing: acknowledge in the channel, DM a
receipt, open a modal. This guide shows how Slink's helpers are meant to be
combined — and why that's `with`, not `|>`.

## The return conventions

Every imported helper takes the `context` first and reports honestly:

| Shape | Helpers | Why |
|---|---|---|
| always `:ok` | `reply/3`, `send_message/4` | fire-and-forget: the send is queued (or posted to a `response_url` whose errors are logged, not returned) — there is no failure the *caller* could act on. Misuse still raises: `reply/3` on an event with no channel, an invalid `to:` |
| `:ok \| {:error, reason}` | `send_dm/4`, `update_original/3`, `set_status/2` | a Slack round-trip whose failure the caller may want to handle |
| `{:ok, data} \| {:error, reason}` | `open_modal/2`, `stream_reply/3` | returns data you may need (the opened view's id; the streamed message's `ts`) |

Because the shapes are consistent, they compose with `with` out of the box.

## Sequencing actions

When later steps should only run if earlier ones worked, chain them with
`with`; the first `{:error, reason}` short-circuits into `else`:

```elixir
def handle_event(%Event{type: :block_actions} = event, context) do
  with :ok <- update_original(context, "processing…"),
       :ok <- send_dm(context, Event.user(event), "receipt: …"),
       {:ok, resp} <- open_modal(context, confirmation_view()) do
    Logger.info("opened #{resp["view"]["id"]}")
  else
    {:error, reason} ->
      reply(context, "something failed: #{inspect(reason)}", to: :ephemeral)
  end
end
```

A handler can end with the `with` directly — the dispatcher treats any return
that isn't `{:reply, …}` / `{:ack, …}` as "no reply", so no trailing `:ok` is
needed.

`with` also reads well as a *fallback* when there's just one failable step:

```elixir
with {:error, reason} <- send_dm(context, user, "psst…") do
  reply(context, "couldn't DM you (#{inspect(reason)}) — posting here instead")
end
```

## Independent actions don't need ceremony

If the actions don't depend on each other, plain statements are the composition:

```elixir
def handle_event(%Event{type: :app_mention} = event, context) do
  reply(context, "on it 👍")
  send_dm(context, Event.user(event), "here's the detail…")
end
```

## Why not a pipe?

`context |> reply("hi") |> send_dm(user, "…")` would require every helper to
return the context, and that trades away things this API deliberately keeps:

  * **Honest errors.** `send_dm/4` can genuinely fail; returning the context
    instead of `{:error, reason}` leaves the failure nowhere to go. `with`
    composes on the *result*, so failures short-circuit instead of vanishing.
  * **Honest ordering.** Sends go through per-channel rate queues and tasks; a
    channel post and a DM can land in either order. A pipe would *read* as
    "first this, then that" — a promise the transport doesn't make. (Messages
    to the *same* channel are FIFO through their queue.)
  * **A clean handler contract.** The dispatcher inspects the handler's return
    value; a context-returning chain would muddy `{:reply, …}` / `{:ack, …}`.

A pipeline that threads an *unchanged* value through side effects is syntax
pretending to be dataflow — `with` is the composition operator for "do these
effects, stop on the first failure", which is what a handler actually means.
