defmodule Slink do
  @moduledoc """
  A lightweight Slack bot toolkit.

  `Slink` gives you one event-handling contract and two interchangeable
  transports:

    * `Slink.SocketMode` — dials **out** to Slack over a WebSocket. No public
      endpoint required. Best for development and internal/behind-firewall apps.
    * `Slink.EventsApi.Plug` — a `Plug` that receives Slack's HTTP event
      callbacks. Best for production and distributed apps.

  Both transports normalise Slack payloads into a `Slink.Event` and dispatch it
  to your module's `c:handle_event/2`. Write your bot once; pick the transport
  per environment (Socket Mode in dev, HTTP in prod — which is exactly what
  Slack recommends).

  ## Defining a bot

      defmodule MyBot do
        use Slink
        alias Slink.Event

        @impl true
        def handle_event(%Slink.Event{type: :app_mention} = event, _context) do
          # Return a reply and slink sends it (placement: to: :auto by default).
          {:reply, "hi <@\#{Event.user(event)}> 👋"}
        end

        def handle_event(_event, _context), do: :ok
      end

  Or reply imperatively — `reply/3` returns `:ok`, so it can be the last
  expression, and `to:` picks where it lands (`:auto`, `:thread`, `:channel`):

      def handle_event(%Slink.Event{type: :app_mention} = event, context) do
        reply(context, Event.command(event), to: :channel)
      end

  Handlers that do several things chain the helpers with `with` — the return
  shapes are consistent, so the first `{:error, reason}` short-circuits. See
  the [Composing helpers](composing.html) guide.

  ## Running it (Socket Mode)

      children = [
        {Slink.SocketMode,
         module: MyBot,
         app_token: System.fetch_env!("SLACK_APP_TOKEN"),
         bot_token: System.fetch_env!("SLACK_BOT_TOKEN")}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  See the module docs for `Slink.EventsApi.Plug` to run the HTTP transport.

  ## Multiple workspaces

  Slink is token-per-request throughout: every `Slink.API` call takes a token,
  the handler context carries the `:bot_token`, and both transports let you pick
  it per workspace. Over Socket Mode you run one client per workspace (see
  `Slink.SocketMode`); over HTTP you pass a `:bot_token` resolver that receives
  the event's team id (see `Slink.EventsApi.Plug`). So one bot module can serve
  many workspaces.

  To *acquire* those tokens as workspaces install your app, use the **OAuth
  install flow** in `Slink.OAuth` — the consent URL, code exchange, and a
  callback plug are done for you. Persisting a token per team is deliberately
  yours: bring your own store; Slink routes to whatever token you hand it.
  """

  require Logger

  @typedoc "Context passed to `c:handle_event/2`. See `Slink.Context`."
  @type context :: Slink.Context.t()

  @doc """
  Whether a bot should start, given its config.

  Returns `true` only when `:enabled` is truthy and both `:app_token` and
  `:bot_token` are present. Use it to conditionally add `Slink.SocketMode` to a
  supervision tree, so an app without credentials (or with the bot switched off)
  simply doesn't connect:

      children =
        if Slink.enabled?(config) do
          [{Slink.SocketMode, [module: MyBot] ++ config}]
        else
          []
        end

  `config` is any keyword list or map (e.g. from `Application.get_env/2`).
  """
  def enabled?(config) do
    !!(config[:enabled] && config[:app_token] && config[:bot_token])
  end

  @typedoc """
  What a handler returns:

    * `:ok` — done, no reply.
    * `{:reply, text}` — slink replies with `text` via `reply/3` with the
      default `to: :auto` placement (threaded if the event is in a thread,
      otherwise inline).
    * `{:reply, text, opts}` — same, passing `opts` to `reply/3`: `to: :thread`
      / `to: :channel` to force placement, and `blocks: [...]` /
      `attachments: [...]` for **rich replies**. `text` is still sent as the
      notification/fallback Slack shows in previews, so always provide something
      meaningful.
    * `{:ack, map}` — only for a `view_submission` (modal submit): `map` is
      Slack's `response_action` reply, e.g.
      `%{response_action: "errors", errors: %{"block" => "…"}}` to show
      validation errors, or `update`/`push` to swap the modal. This event type
      runs synchronously, so return promptly. Any other return closes the modal.

  Any other value is treated as `:ok` (no reply).
  """
  @type result ::
          :ok | {:reply, String.t()} | {:reply, String.t(), keyword()} | {:ack, map()}

  @doc """
  Invoked for every event Slack delivers, from either transport.

  Return `:ok` to do nothing, or `{:reply, text}` to reply (see `t:result/0`).
  The transport has already acknowledged the event to Slack before this runs,
  so slow work here never risks Slack's 3-second ACK window.
  """
  @callback handle_event(Slink.Event.t(), context()) :: result()

  @doc """
  Post a message to `channel`, using the bot token from the handler `context`.

  Goes through `Slink.Rate` so sends are rate-limited per channel (Slack allows
  ~1/sec/channel). `opts` — a keyword list or map — is merged into the request
  body (e.g. `blocks:`, `thread_ts:`), matching `reply/3`'s keyword opts. Returns
  `:ok`. `use Slink` imports this, so handlers can call it unqualified:

      def handle_event(%Slink.Event{type: :app_mention} = event, context) do
        send_message(context, Slink.Event.channel(event), "hi")
      end
  """
  def send_message(%Slink.Context{bot_token: token}, channel, text, opts \\ []) do
    Slink.Rate.post_message(token, channel, text, Map.new(opts))
  end

  @doc """
  Send a direct message to `user`, using the bot token from the handler
  `context` (imported by `use Slink`).

  Opens (or resumes) the DM conversation via `conversations.open`, then posts
  through `Slink.Rate` like `send_message/4`. `opts` merges into the request
  body (`blocks:` etc.). Returns `:ok`, or `{:error, reason}` if the DM
  couldn't be opened (e.g. the app lacks the `im:write` scope).

      def handle_event(%Slink.Event{type: :team_join} = event, context) do
        send_dm(context, Slink.Event.user(event), "welcome aboard 👋")
      end
  """
  def send_dm(%Slink.Context{bot_token: token}, user, text, opts \\ []) do
    case Slink.API.open_dm(token, user) do
      {:ok, channel} -> Slink.Rate.post_message(token, channel, text, Map.new(opts))
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether the bot itself is @-mentioned in the event's text (imported by
  `use Slink`).

  Unlike matching on `:app_mention` — a whole event type — this answers the
  question for *any* event carrying text, e.g. a `:message` in a thread the bot
  is following. Compares against `context.bot_user_id`, which is discovered via
  `auth.test` shortly after the transport starts; returns `false` while that's
  still unknown (and `:app_mention` events don't need it anyway).
  """
  def mentions_me?(%Slink.Context{bot_user_id: id, event: %Slink.Event{} = event})
      when is_binary(id),
      do: Slink.Event.mentions?(event, id)

  def mentions_me?(%Slink.Context{}), do: false

  @doc """
  Whether the event happened inside a thread (imported by `use Slink`).

  Accepts either a `context` (like the other imported helpers) or a bare
  `Slink.Event`. Delegates to `Slink.Event.in_thread?/1`.
  """
  def in_thread?(%Slink.Context{event: event}), do: in_thread?(event)
  def in_thread?(%Slink.Event{} = event), do: Slink.Event.in_thread?(event)
  def in_thread?(nil), do: false

  @doc """
  Reply to the event in `context` (imported by `use Slink`). Returns `:ok`, so a
  handler can end with it — no trailing `:ok` needed:

      def handle_event(%Slink.Event{type: :app_mention} = event, context) do
        reply(context, "on it 👍")
      end

  The channel and thread come from `context.event` (set by the dispatcher), so
  no event argument is needed. This works the same for a `block_actions`
  interaction (a button click): the reply lands on the message the button is on.
  Where the reply lands is controlled by `opts[:to]`:

    * `:auto` (default) — **dynamic**: in the thread if the event is in one,
      otherwise inline in the channel.
    * `:thread` — always in a thread: the event's existing thread, or a new one
      started on the triggering message.
    * `:channel` — always inline in the channel timeline, even if the event was
      inside a thread.
    * `:ephemeral` — visible **only to the user who triggered the event**, and
      gone on reload. Interactions go through their `response_url`; plain
      events (a mention, a message) use `chat.postEphemeral`.

  Every other key in `opts` is merged into the Slack request body, for **rich
  replies**: `blocks: [...]` (Block Kit), `attachments: [...]`, an explicit
  `thread_ts:`, etc.

      reply(context, "deployed ✅", to: :channel, blocks: blocks)

  For a **slash command** the reply goes to the command's `response_url` instead,
  with `to: :ephemeral` (default, only the invoker) or `to: :channel`.

  An interaction with **no channel to post into** (a button on an ephemeral
  message, a message in a channel the bot isn't a member of) falls back to its
  `response_url` — ephemeral to the invoker, or in-channel with `to: :channel` —
  rather than failing. To *replace* the message a button lives on instead of
  posting a new one, see `update_original/3`.
  """
  def reply(context, text, opts \\ [])

  def reply(
        %Slink.Context{event: %Slink.Event{kind: :slash_commands} = event} = context,
        text,
        opts
      ) do
    # Slash commands reply through their response_url; `to:` picks visibility —
    # `:ephemeral` (default, only the invoker) or `:channel`. On the off chance
    # there's no response_url, fall back to a plain channel post.
    case Slink.Event.response_url(event) do
      url when is_binary(url) ->
        {to, body} = Keyword.pop(opts, :to, :ephemeral)
        params = body |> Map.new() |> Map.merge(%{text: text, response_type: slash_type(to)})
        _ = Slink.API.respond(url, params)
        :ok

      _ ->
        {_to, body} = Keyword.pop(opts, :to)
        send_message(context, Slink.Event.channel(event), text, Map.new(body))
    end
  end

  def reply(%Slink.Context{event: %Slink.Event{} = event} = context, text, opts) do
    {to, body} = Keyword.pop(opts, :to, :auto)
    channel = Slink.Event.channel(event)

    cond do
      to == :ephemeral ->
        ephemeral_reply(context, event, channel, text, Map.new(body))

      is_binary(channel) ->
        send_message(context, channel, text, thread(body, to, event))

      is_binary(Slink.Event.response_url(event)) ->
        # No channel to post into (a click on an ephemeral message, a channel
        # the bot isn't in) — Slack provides the response_url exactly for this.
        respond_via_url(event, text, Map.new(body), responder_type(to))

      true ->
        raise ArgumentError,
              "reply/3 has no channel for a #{inspect(event.type)} event (a global shortcut " <>
                "or view interaction happens outside a channel); use open_modal/2 or " <>
                "send_message/4 — or return {:ack, map} from a view_submission"
    end
  end

  def reply(%Slink.Context{event: nil}, _text, _opts) do
    raise ArgumentError,
          "reply/3 requires context.event; call it from a handler (the dispatcher sets the event) " <>
            "or use send_message/4 for an arbitrary channel"
  end

  # An ephemeral reply: interactions carry a response_url built for it (and it
  # also works on ephemeral messages / non-member channels); plain events use
  # chat.postEphemeral, which needs the channel and the triggering user.
  defp ephemeral_reply(context, event, channel, text, body) do
    cond do
      url = Slink.Event.response_url(event) ->
        params = Map.merge(body, %{text: text, response_type: "ephemeral"})
        _ = Slink.API.respond(url, Map.put_new(params, :replace_original, false))
        :ok

      is_binary(channel) and is_binary(Slink.Event.user(event)) ->
        params =
          Map.merge(body, %{channel: channel, user: Slink.Event.user(event), text: text})

        Slink.Rate.enqueue(context.bot_token, channel, "chat.postEphemeral", params)

      true ->
        raise ArgumentError,
              "reply/3 with to: :ephemeral needs a response_url (interactions, slash commands) " <>
                "or a channel and user (message events) — a #{inspect(event.type)} event has neither"
    end
  end

  defp respond_via_url(event, text, body, response_type) do
    params = Map.merge(body, %{text: text, response_type: response_type})

    _ =
      Slink.API.respond(
        Slink.Event.response_url(event),
        Map.put_new(params, :replace_original, false)
      )

    :ok
  end

  # Placement for the no-channel response_url fallback: :channel means everyone,
  # anything thread-ish degrades to ephemeral (there is no thread to target).
  defp responder_type(:channel), do: "in_channel"
  defp responder_type(to) when to in [:auto, :thread], do: "ephemeral"

  defp responder_type(other) do
    raise ArgumentError,
          "invalid `to: #{inspect(other)}` for a message reply; use :auto, :thread, :channel, or :ephemeral"
  end

  # Add thread_ts only when the placement is threaded and we actually have a
  # timestamp to thread under — never send a nil thread_ts.
  defp thread(body, to, event) do
    body = Map.new(body)

    with true <- threaded?(to, event),
         ts when is_binary(ts) <- Slink.Event.reply_thread(event) do
      Map.put_new(body, :thread_ts, ts)
    else
      _ -> body
    end
  end

  defp threaded?(:thread, _event), do: true
  defp threaded?(:channel, _event), do: false
  defp threaded?(:auto, event), do: in_thread?(event)

  defp threaded?(other, _event) do
    raise ArgumentError,
          "invalid `to: #{inspect(other)}` for a message reply; use :auto, :thread, :channel, " <>
            "or :ephemeral"
  end

  defp slash_type(:ephemeral), do: "ephemeral"
  defp slash_type(:channel), do: "in_channel"

  defp slash_type(other) do
    raise ArgumentError,
          "invalid `to: #{inspect(other)}` for a slash-command reply; use :ephemeral or :channel"
  end

  @doc """
  Open a modal in response to the interaction or slash command in `context`
  (imported by `use Slink`).

  Returns `{:ok, response} | {:error, reason}` — the standard shape for a call
  that returns data and can fail. `response` is Slack's `views.open` payload, so
  `response["view"]["id"]` is the id you pass to `update_view/3` later.
  (`push_view/3` instead takes a fresh `trigger_id` from a later interaction
  inside the modal, not the opened view's id.) You can also just end a handler
  with it: the dispatcher treats a
  non-`{:reply, …}`/`{:ack, …}` return as "no reply" (see `t:result/0`), so a
  bare `open_modal(context, view)` is fine and no trailing `:ok` is needed.

  Uses the event's `trigger_id`, which Slack honours for only ~3 seconds, so open
  promptly. `view` is a Block Kit view map.

      def handle_event(%Slink.Event{type: :shortcut} = _event, context) do
        open_modal(context, my_view())
      end
  """
  def open_modal(%Slink.Context{bot_token: token, event: %Slink.Event{} = event}, view) do
    Slink.API.open_view(token, Slink.Event.trigger_id(event), view)
  end

  @doc """
  Replace the message this interaction came from (imported by `use Slink`).

  The canonical "a button click updates its own message" pattern: posts to the
  event's `response_url` with `replace_original: true`, so it also works on
  ephemeral messages and in channels the bot isn't a member of — places
  `Slink.API.update_message/5` can't reach. `opts` merges into the body
  (`blocks:` etc.).

      def handle_event(%Slink.Event{type: :block_actions} = event, context) do
        update_original(context, "deploying \#{Event.action_value(event)}…")
      end

  Returns `:ok`, or `{:error, :no_response_url}` when the event carries none
  (only slash commands and message interactions do — not plain events), or the
  responder's `{:error, reason}`.
  """
  def update_original(context, text, opts \\ [])

  def update_original(%Slink.Context{event: %Slink.Event{} = event}, text, opts) do
    case Slink.Event.response_url(event) do
      url when is_binary(url) ->
        params = opts |> Map.new() |> Map.merge(%{text: text, replace_original: true})

        case Slink.API.respond(url, params) do
          {:ok, _body} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :no_response_url}
    end
  end

  def update_original(%Slink.Context{event: nil}, _text, _opts), do: {:error, :no_response_url}

  @stream_flush_ms 400
  # Flush well before Slack's per-append cap so buffers stay small.
  @stream_flush_bytes 4_000
  # Slack rejects markdown_text over 12k characters — never send more per call.
  @stream_append_max 12_000

  @doc """
  Stream a reply into the event's thread, chunk by chunk (imported by
  `use Slink`).

  Built for AI apps: pass any enumerable of text chunks — an LLM token stream,
  a `Stream`, a list — and it renders as one live, progressively-updating
  Slack message via `chat.startStream` / `appendStream` / `stopStream`:

      def handle_event(%Slink.Event{type: :message} = event, context) do
        set_status(context, "is thinking…")
        stream_reply(context, MyLLM.stream(Slink.Event.text(event)))
      end

  Chunks are buffered and appended at most every `:flush_ms` (default
  #{@stream_flush_ms}ms), so a fast token stream doesn't hammer Slack's limits.
  Streamed messages are always thread replies: the event's thread, or a new
  one on the triggering message (like `reply/3` with `to: :thread`). If the
  surface can't stream (the method errors — e.g. the feature isn't enabled for
  the app), it **degrades to a single `chat.postMessage`** with the full text,
  so the reply still arrives.

  Returns `{:ok, ts}` of the streamed (or fallback) message, or
  `{:error, reason}` when both paths failed. The enumerable is fully consumed
  either way. Raises `ArgumentError` for an event with no channel or nothing
  to thread under (a global shortcut, a modal submit). A `chat.stopStream`
  failure after a successful stream still returns `{:ok, ts}` — the message
  exists with everything appended — and logs what the failed stop was
  carrying (a `:finish` payload, trailing text).

  Options:

    * `:flush_ms` — minimum interval between appends (default #{@stream_flush_ms}).
    * `:start` — extra `chat.startStream` params; streaming into a *channel*
      (not the app's DM) requires `%{recipient_user_id: ..., recipient_team_id: ...}`.
    * `:finish` — extra `chat.stopStream` params (e.g. `%{blocks: [...]}` —
      blocks are allowed only on the final call).
  """
  def stream_reply(context, enumerable, opts \\ [])

  def stream_reply(
        %Slink.Context{bot_token: token, event: %Slink.Event{} = event},
        enumerable,
        opts
      ) do
    channel = Slink.Event.channel(event)
    thread_ts = Slink.Event.reply_thread(event)

    if is_binary(channel) and is_binary(thread_ts) do
      do_stream(token, channel, thread_ts, enumerable, opts)
    else
      raise ArgumentError,
            "stream_reply/3 needs a channel and a message to thread under; " <>
              "a #{inspect(event.type)} event has neither"
    end
  end

  defp do_stream(token, channel, thread_ts, enumerable, opts) do
    case Slink.API.start_stream(token, channel, thread_ts, Map.new(opts[:start] || %{})) do
      {:ok, %{"ts" => ts}} ->
        rest =
          stream_chunks(
            token,
            channel,
            ts,
            enumerable,
            Keyword.get(opts, :flush_ms, @stream_flush_ms)
          )

        finish_stream(token, channel, ts, rest, Map.new(opts[:finish] || %{}))

      {:error, _reason} ->
        # No streaming on this surface — degrade to one plain post.
        text = Enum.join(enumerable)

        case Slink.API.post_message(token, channel, text, %{thread_ts: thread_ts}) do
          {:ok, %{"ts" => ts}} -> {:ok, ts}
          {:ok, _body} -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Accumulate chunks, appending a batch whenever the flush interval has passed
  # (or the buffer nears the cap). A failed append keeps its text buffered —
  # worst case everything lands in the final stop_stream.
  defp stream_chunks(token, channel, ts, enumerable, flush_ms) do
    {buffer, _last} =
      Enum.reduce(enumerable, {"", System.monotonic_time(:millisecond)}, fn chunk,
                                                                            {buffer, last} ->
        buffer = buffer <> to_string(chunk)
        now = System.monotonic_time(:millisecond)

        if buffer != "" and (now - last >= flush_ms or byte_size(buffer) >= @stream_flush_bytes) do
          {append_slices(token, channel, ts, buffer), now}
        else
          {buffer, last}
        end
      end)

    buffer
  end

  # Append `buffer` in ≤@stream_append_max-char slices — one huge chunk (or a
  # buffer grown past the cap by failed appends) must never produce an
  # over-cap call, which Slack would reject wholesale. Returns whatever could
  # not be delivered.
  defp append_slices(_token, _channel, _ts, ""), do: ""

  defp append_slices(token, channel, ts, buffer) do
    {slice, rest} = String.split_at(buffer, @stream_append_max)

    case Slink.API.append_stream(token, channel, ts, slice) do
      {:ok, _body} -> append_slices(token, channel, ts, rest)
      {:error, _reason} -> slice <> rest
    end
  end

  # Small leftovers ride the stop call (prepended to any user-supplied final
  # markdown_text, never clobbering it); an oversized remainder is drained
  # through capped appends first.
  defp finish_stream(token, channel, ts, rest, finish) do
    rest =
      if String.length(rest) > @stream_append_max do
        append_slices(token, channel, ts, rest)
      else
        rest
      end

    finish =
      if rest == "" do
        finish
      else
        Map.update(finish, :markdown_text, rest, &(rest <> &1))
      end

    case Slink.API.stop_stream(token, channel, ts, finish) do
      {:ok, _body} ->
        {:ok, ts}

      {:error, reason} ->
        # The message exists and holds everything appended so far — report
        # success, but say plainly if the failed stop was carrying text.
        dropped =
          if finish[:markdown_text], do: " — its trailing markdown_text was not delivered"

        Logger.warning("Slink: chat.stopStream failed (#{inspect(reason)})#{dropped}")
        {:ok, ts}
    end
  end

  @doc """
  Show a status line under the assistant thread of the event in `context` —
  "is thinking…" while the real answer is prepared (imported by `use Slink`).

  Wraps `Slink.API.set_thread_status/4` with the event's channel and thread.
  Pass `""` to clear; posting or streaming a reply into the thread clears it
  automatically. Returns `:ok | {:error, reason}`. Needs the `assistant:write`
  scope.
  """
  def set_status(%Slink.Context{bot_token: token, event: %Slink.Event{} = event}, status) do
    case Slink.API.set_thread_status(
           token,
           Slink.Event.channel(event),
           Slink.Event.reply_thread(event),
           status
         ) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @working_emoji "hourglass_flowing_sand"
  @working_delay_ms to_timeout(second: 3)

  @doc """
  Show a "working on it" indicator on the triggering message *only if* the work
  is slow, then clear it (imported by `use Slink`). Returns whatever `fun`
  returns.

  Slack has no bot "typing…" indicator for channels, so this reacts to the
  event's message with an emoji (default `#{@working_emoji}` ⏳). To avoid a
  pointless flicker on fast replies, `fun` runs in a task and the reaction is
  added **only if it's still running after `:delay_ms`** (default #{@working_delay_ms}ms);
  it's always removed once `fun` finishes — even if it raises. Fast work shows
  nothing. So it's safe to wrap any handler:

      def handle_event(%Slink.Event{type: :app_mention} = event, context) do
        working(context, fn -> reply(context, answer(event)) end)
      end

  Options:

    * `:delay_ms` — how long to wait before showing the indicator (default
      `#{@working_delay_ms}`). Use `0` to show it immediately.
    * `:emoji` — reaction name without colons (default `"#{@working_emoji}"`).

  Best-effort: reaction API errors are ignored so they never break the handler,
  and if the event has no message to react to, `fun` just runs inline. One
  caveat: if the app is shut down mid-work (a deploy, a `:brutal_kill`), the
  removal never runs and the reaction can be left on the message.
  """
  def working(context, fun, opts \\ [])

  def working(%Slink.Context{event: %Slink.Event{} = event} = context, fun, opts)
      when is_function(fun, 0) do
    channel = Slink.Event.channel(event)
    ts = Slink.Event.ts(event)

    if is_binary(channel) and is_binary(ts) do
      emoji = Keyword.get(opts, :emoji, @working_emoji)
      delay = Keyword.get(opts, :delay_ms, @working_delay_ms)
      with_indicator(context, fun, channel, ts, emoji, delay)
    else
      fun.()
    end
  end

  # Run fun in a task; add the reaction only if it hasn't finished within `delay`,
  # and always remove it once fun completes. A task exit is re-propagated so a
  # crashing handler still crashes as it would run inline.
  defp with_indicator(context, fun, channel, ts, emoji, delay) do
    task = Task.Supervisor.async_nolink(Slink.TaskSupervisor, fun)

    case Task.yield(task, delay) do
      nil ->
        # Still running after `delay`: show the indicator, wait for the result,
        # then always clear it.
        _ = Slink.API.add_reaction(context.bot_token, channel, ts, emoji)

        try do
          unwrap(Task.yield(task, :infinity))
        after
          _ = Slink.API.remove_reaction(context.bot_token, channel, ts, emoji)
        end

      yielded ->
        unwrap(yielded)
    end
  end

  # A task exit is re-propagated so a crashing handler still crashes as it would
  # have run inline.
  defp unwrap({:ok, result}), do: result
  defp unwrap({:exit, reason}), do: exit(reason)

  defmacro __using__(_opts) do
    quote do
      @behaviour Slink

      import Slink,
        only: [
          send_message: 3,
          send_message: 4,
          send_dm: 3,
          send_dm: 4,
          reply: 2,
          reply: 3,
          stream_reply: 2,
          stream_reply: 3,
          set_status: 2,
          update_original: 2,
          update_original: 3,
          working: 2,
          working: 3,
          open_modal: 2,
          in_thread?: 1,
          mentions_me?: 1
        ]
    end
  end
end
