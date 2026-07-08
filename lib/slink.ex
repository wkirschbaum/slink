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
        alias Slink.API

        @impl true
        def handle_event(%Slink.Event{type: "app_mention", payload: e}, context) do
          API.post_message(context.bot_token, e["channel"], "hi <@\#{e["user"]}> 👋")
          :ok
        end

        def handle_event(_event, _context), do: :ok
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
  Invoked for every event Slack delivers, from either transport.

  Return `:ok`. The transport has already acknowledged the event to Slack
  before this runs, so slow work here never risks Slack's 3-second ACK window.
  """
  @callback handle_event(Slink.Event.t(), context()) :: :ok

  @doc """
  Post a message to `channel`, using the bot token from the handler `context`.

  Goes through `Slink.Rate` so sends are rate-limited per channel (Slack allows
  ~1/sec/channel). `opts` is merged into the request body (e.g. `blocks`,
  `thread_ts`). `use Slink` imports this, so handlers can call it unqualified:

      def handle_event(%Slink.Event{type: "app_mention"} = event, context) do
        send_message(context, Slink.Event.channel(event), "hi")
      end
  """
  @spec send_message(context(), String.t(), String.t(), map()) :: :ok
  def send_message(%Slink.Context{bot_token: token}, channel, text, opts \\ %{}) do
    Slink.Rate.post_message(token, channel, text, opts)
  end

  @doc """
  Reply to an `event` in its thread (imported by `use Slink`).

  Posts to the event's channel with `thread_ts` set to the event's thread — or,
  if the event isn't in a thread yet, to the event's own message, *starting* a
  thread on it. So a reply always stays threaded with what triggered it:

      def handle_event(%Slink.Event{type: "app_mention"} = event, context) do
        reply(context, event, "on it 👍")
      end

  `opts` is merged into the request body. To reply in the channel (not threaded),
  use `send_message/4` instead.
  """
  @spec reply(context(), Slink.Event.t(), String.t(), map()) :: :ok
  def reply(%Slink.Context{} = context, %Slink.Event{} = event, text, opts \\ %{}) do
    opts = Map.put_new(opts, :thread_ts, Slink.Event.reply_thread(event))
    send_message(context, Slink.Event.channel(event), text, opts)
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Slink
      import Slink, only: [send_message: 3, send_message: 4, reply: 3, reply: 4]
    end
  end
end
