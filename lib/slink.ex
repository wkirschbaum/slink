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

  ## Running it (Socket Mode)

      children = [
        {Slink.SocketMode,
         module: MyBot,
         app_token: System.fetch_env!("SLACK_APP_TOKEN"),
         bot_token: System.fetch_env!("SLACK_BOT_TOKEN")}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  See the module docs for `Slink.EventsApi.Plug` to run the HTTP transport.
  """

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
  @spec enabled?(keyword() | map()) :: boolean()
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

  Any other value is treated as `:ok` (no reply).
  """
  @type result :: :ok | {:reply, String.t()} | {:reply, String.t(), keyword()}

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
  ~1/sec/channel). `opts` is merged into the request body (e.g. `blocks`,
  `thread_ts`). `use Slink` imports this, so handlers can call it unqualified:

      def handle_event(%Slink.Event{type: :app_mention} = event, context) do
        send_message(context, Slink.Event.channel(event), "hi")
      end
  """
  @spec send_message(context(), String.t(), String.t(), map()) :: :ok
  def send_message(%Slink.Context{bot_token: token}, channel, text, opts \\ %{}) do
    Slink.Rate.post_message(token, channel, text, opts)
  end

  @doc """
  Whether `event` happened inside a thread (imported by `use Slink`).

  Delegates to `Slink.Event.in_thread?/1`.
  """
  @spec in_thread?(Slink.Event.t()) :: boolean()
  defdelegate in_thread?(event), to: Slink.Event

  @doc """
  Reply to the event in `context` (imported by `use Slink`). Returns `:ok`, so a
  handler can end with it — no trailing `:ok` needed:

      def handle_event(%Slink.Event{type: :app_mention} = event, context) do
        reply(context, "on it 👍")
      end

  The channel and thread come from `context.event` (set by the dispatcher), so
  no event argument is needed. Where the reply lands is controlled by `opts[:to]`:

    * `:auto` (default) — **dynamic**: in the thread if the event is in one,
      otherwise inline in the channel.
    * `:thread` — always in a thread: the event's existing thread, or a new one
      started on the triggering message.
    * `:channel` — always inline in the channel timeline, even if the event was
      inside a thread.

  Every other key in `opts` is merged into the Slack request body, for **rich
  replies**: `blocks: [...]` (Block Kit), `attachments: [...]`, an explicit
  `thread_ts:`, etc.

      reply(context, "deployed ✅", to: :channel, blocks: blocks)
  """
  @spec reply(context(), String.t(), keyword()) :: :ok
  def reply(context, text, opts \\ [])

  def reply(%Slink.Context{event: %Slink.Event{} = event} = context, text, opts) do
    {to, body} = Keyword.pop(opts, :to, :auto)
    send_message(context, Slink.Event.channel(event), text, thread(body, to, event))
  end

  def reply(%Slink.Context{event: nil}, _text, _opts) do
    raise ArgumentError,
          "reply/3 requires context.event; call it from a handler (the dispatcher sets the event) " <>
            "or use send_message/4 for an arbitrary channel"
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

  defmacro __using__(_opts) do
    quote do
      @behaviour Slink

      import Slink, only: [send_message: 3, send_message: 4, reply: 2, reply: 3, in_thread?: 1]
    end
  end
end
