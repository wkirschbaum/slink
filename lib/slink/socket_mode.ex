defmodule Slink.SocketMode do
  @moduledoc """
  Socket Mode transport: a `GenServer` that keeps a WebSocket open to Slack.

  It opens a connection URL via `apps.connections.open`, upgrades to a
  WebSocket with `Mint.WebSocket`, acknowledges every envelope immediately
  (Slack requires an ACK within 3 seconds), and dispatches the decoded event to
  your module off-process. Slack's periodic `disconnect` refreshes and dropped
  connections are handled by transparently reconnecting.

  Add it to a supervision tree:

      {Slink.SocketMode,
       module: MyBot,
       app_token: System.fetch_env!("SLACK_APP_TOKEN"),
       bot_token: System.fetch_env!("SLACK_BOT_TOKEN")}

  Options:

    * `:module` (required) — a module implementing the `Slink` behaviour.
    * `:app_token` (required) — app-level token (`xapp-…`, `connections:write`).
    * `:bot_token` — bot token (`xoxb-…`) passed to handlers for Web API calls.
    * `:name` — process name (defaults to `Slink.SocketMode`; pass `nil` to run
      unregistered, e.g. to run several clients at once).
    * `:join` — a list of channel IDs to `conversations.join` once connected
      (requires the `channels:join` scope). Defaults to `[]`.
    * `:open_connection` — a 0-arity function returning `{:ok, ws_url}` used to
      obtain the WebSocket URL. Defaults to calling `apps.connections.open` with
      `:app_token`. Primarily a testing seam.
    * `:verbose` — when `true`, log every incoming WebSocket frame at `:info`
      (raw text for text frames). Useful for debugging what Slack actually
      delivers. Defaults to `false`.
    * `:idle_timeout_ms` — reconnect if no traffic (frames, pings, any TCP data)
      arrives for this long, catching connections that died without a close
      (NAT timeout, network partition). Slack pings every few seconds, so a
      quiet-but-healthy link never trips this. Milliseconds (or `:infinity` to
      disable); defaults to 2 minutes.

  ## Multiple workspaces

  Run one client per workspace — each dials out with its own tokens and stamps
  its own `:bot_token` into the handler context, so a single `MyBot` serves them
  all. Give each a distinct `:name`:

      for w <- MyApp.workspaces() do
        {Slink.SocketMode,
         name: {:global, {MyBot, w.team_id}},
         module: MyBot,
         app_token: w.app_token,
         bot_token: w.bot_token}
      end
  """

  use GenServer
  require Logger

  alias Slink.{API, Context, Dispatcher, Event}

  @base_backoff to_timeout(second: 1)
  @max_backoff to_timeout(second: 30)
  @default_idle_timeout to_timeout(minute: 2)

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  # Key the child id off `:name` so running one client per workspace under a
  # single supervisor doesn't collide on the default `id: __MODULE__`. Give each
  # a distinct `:name` (see *Multiple workspaces*) and their ids differ too.
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @impl true
  def init(opts) do
    app_token = Keyword.get(opts, :app_token)

    open_connection =
      Keyword.get(opts, :open_connection, fn -> API.open_connection(app_token) end)

    state = %{
      module: Keyword.fetch!(opts, :module),
      bot_token: Keyword.get(opts, :bot_token),
      join: Keyword.get(opts, :join, []),
      verbose: Keyword.get(opts, :verbose, false),
      open_connection: open_connection,
      conn: nil,
      websocket: nil,
      request_ref: nil,
      status: nil,
      resp_headers: nil,
      # WebSocket frame bytes that arrive in the same batch as the upgrade
      # response, before {:done} creates the websocket. Buffered here, then
      # decoded the moment the websocket exists. See handle_response/2.
      pending: "",
      # consecutive-failure counter driving reconnect backoff; reset on hello.
      backoff: 0,
      # liveness watchdog: when the last traffic arrived, and how long silence
      # may last before the connection is declared dead. See :idle_check.
      idle_timeout: Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout),
      last_activity: System.monotonic_time(:millisecond)
    }

    {:ok, schedule_idle_check(state), {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, connect(state)}
  end

  # Crash reports and :sys.get_status print the full state — keep the bot token
  # out of logs. (The open_connection closure captures the app token too, but
  # closures inspect opaquely, so it never prints.)
  @impl true
  def format_status(status) do
    Map.replace_lazy(status, :state, fn state ->
      %{state | bot_token: redact(state.bot_token)}
    end)
  end

  defp redact(nil), do: nil
  defp redact(_token), do: "[REDACTED]"

  @impl true
  def handle_info(:connect, %{conn: nil} = state) do
    {:noreply, connect(state)}
  end

  # A stray reconnect timer while already connected. Slack's `disconnect`
  # message and the server's close frame can land in one batch, each scheduling
  # a reconnect — honouring both would open a second connection and leak the
  # first, so any :connect after the first has done its job is dropped.
  def handle_info(:connect, state), do: {:noreply, state}

  # Liveness watchdog: Slack pings every few seconds, so a connection with no
  # traffic for idle_timeout is dead even if the TCP socket never errored
  # (NAT timeout, network partition). Without this, a silently dropped
  # connection would leave the bot deaf forever. `conn != nil` (rather than
  # websocket) also catches an upgrade that black-holes before completing.
  def handle_info(:idle_check, state) do
    state =
      if state.conn != nil and
           System.monotonic_time(:millisecond) - state.last_activity > state.idle_timeout do
        Logger.warning("Slink: no traffic for #{state.idle_timeout}ms; reconnecting")
        reconnect(state)
      else
        state
      end

    {:noreply, schedule_idle_check(state)}
  end

  # Mint delivers transport messages (tcp/ssl) here.
  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        # Any traffic on our connection proves the link is alive.
        state = %{state | conn: conn, last_activity: System.monotonic_time(:millisecond)}
        {:noreply, handle_responses(state, responses)}

      {:error, conn, reason, _responses} ->
        Logger.warning("Slink socket stream error: #{inspect(reason)}")
        {:noreply, reconnect(%{state | conn: conn})}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Connection lifecycle

  # Every failure here schedules a retry and returns a valid state — a bad token,
  # DNS failure, or Slack outage must never crash the process (or the host app).
  # This runs in handle_continue/handle_info, so the try/rescue/catch matters:
  # open_connection.() (e.g. Req with a nil app_token) *raises* rather than
  # returning an error, and an unrescued raise here would crash the GenServer
  # before retry/1's backoff, escalating into a supervisor restart loop.
  defp connect(state) do
    Logger.debug("Slink: opening Socket Mode connection")

    case state.open_connection.() do
      {:ok, url} when is_binary(url) ->
        open_socket(state, URI.parse(url))

      other ->
        Logger.error("Slink: could not obtain connection URL (#{inspect(other)}), retrying")
        retry(state)
    end
  rescue
    e ->
      Logger.error("Slink: connect raised (#{inspect(e)}), retrying")
      retry(state)
  catch
    kind, reason ->
      Logger.error("Slink: connect #{kind}ed (#{inspect(reason)}), retrying")
      retry(state)
  end

  defp open_socket(state, %URI{host: host} = uri) when is_binary(host) do
    {http_scheme, ws_scheme} = schemes(uri.scheme)

    case Mint.HTTP.connect(http_scheme, host, uri.port, protocols: [:http1]) do
      {:ok, conn} ->
        case Mint.WebSocket.upgrade(ws_scheme, conn, path(uri), []) do
          {:ok, conn, ref} ->
            # reset_stream/1 clears the frame-assembly buffers here (not only on
            # disconnect): a reconnect firing mid-batch can buffer trailing bytes
            # from the *old* connection, and decoding those against the new
            # websocket would corrupt its framing. last_activity restarts the
            # idle clock for this attempt.
            reset_stream(%{
              state
              | conn: conn,
                request_ref: ref,
                last_activity: System.monotonic_time(:millisecond)
            })

          {:error, conn, reason} ->
            Logger.error("Slink: upgrade failed (#{inspect(reason)}), retrying")
            safe_close(conn)
            retry(state)
        end

      {:error, reason} ->
        Logger.error("Slink: connect failed (#{inspect(reason)}), retrying")
        retry(state)
    end
  end

  defp open_socket(state, uri) do
    Logger.error("Slink: malformed connection URL (#{inspect(uri)}), retrying")
    retry(state)
  end

  # Failed to establish a connection — back off and try again.
  defp retry(state), do: schedule_reconnect(state)

  # A previously-live connection dropped — close it, then back off and reconnect.
  defp reconnect(state) do
    emit([:slink, :socket, :disconnected], state.module)
    safe_close(state.conn)
    schedule_reconnect(state)
  end

  # One scheduler for both paths. Delay grows exponentially with consecutive
  # failures (reset on a successful connect) and is jittered to avoid every
  # client reconnecting in lockstep after a Slack blip.
  defp schedule_reconnect(state) do
    delay = backoff_delay(state.backoff)
    Logger.debug("Slink: reconnecting in #{delay}ms")
    Process.send_after(self(), :connect, delay)

    reset_stream(%{
      state
      | conn: nil,
        websocket: nil,
        request_ref: nil,
        backoff: state.backoff + 1
    })
  end

  defp backoff_delay(attempt) do
    capped = min(@base_backoff * Integer.pow(2, min(attempt, 10)), @max_backoff)
    # Full jitter over the lower half: delay ∈ [capped/2, capped].
    half = div(capped, 2)
    half + :rand.uniform(half)
  end

  # One repeating watchdog timer for the life of the process (see :idle_check).
  # Checking at half the timeout bounds detection latency to ~1.5× the timeout.
  defp schedule_idle_check(%{idle_timeout: :infinity} = state), do: state

  defp schedule_idle_check(state) do
    Process.send_after(self(), :idle_check, max(div(state.idle_timeout, 2), 50))
    state
  end

  defp safe_close(nil), do: :ok
  defp safe_close(conn), do: Mint.HTTP.close(conn)

  defp path(%URI{path: path, query: nil}), do: path || "/"
  defp path(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query

  defp schemes("ws"), do: {:http, :ws}
  defp schemes(_wss), do: {:https, :wss}

  # Clear the HTTP-upgrade/frame-assembly buffers. Single-sourced so a fresh
  # connection and a reconnect can't drift on which fields get reset.
  defp reset_stream(state), do: %{state | status: nil, resp_headers: nil, pending: ""}

  # Emit a socket-lifecycle telemetry event with a consistent measurement/metadata shape.
  defp emit(event, module) do
    :telemetry.execute(event, %{system_time: System.system_time()}, %{module: module})
  end

  ## HTTP-upgrade + WebSocket-frame responses

  defp handle_responses(state, responses) do
    Enum.reduce(responses, state, &handle_response/2)
  end

  defp handle_response({:status, _ref, status}, state), do: %{state | status: status}
  defp handle_response({:headers, _ref, headers}, state), do: %{state | resp_headers: headers}

  defp handle_response({:done, ref}, state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        Logger.info("Slink: Socket Mode connected")
        emit([:slink, :socket, :connected], state.module)

        # Flush any frame bytes that arrived before this {:done} (see the
        # websocket: nil clause of handle_response/2 below). The backoff counter
        # is deliberately NOT reset here but on hello: only Slack's app-level
        # greeting proves the connection was accepted, so a handshake that
        # succeeds and is immediately disconnected still backs off.
        state = %{state | conn: conn, websocket: websocket}
        flush_pending(state)

      {:error, conn, reason} ->
        Logger.error("Slink: WebSocket handshake failed (#{inspect(reason)})")
        reconnect(%{state | conn: conn})
    end
  end

  defp handle_response({:data, _ref, data}, %{websocket: ws} = state) when ws != nil do
    decode_frames(state, data)
  end

  # Frames can arrive in the *same* response batch as the upgrade, ordered
  # before the {:done} that creates the websocket. Mint emits
  # `[:status, :headers, :data, :done]` whenever the server pushes WebSocket
  # frames in the same TCP segment as its 101 response — which Slack does (it
  # sends `hello`, and often the first envelope, immediately on connect). At
  # that point `websocket` is still nil, so we must buffer the bytes rather than
  # drop them; `flush_pending/1` decodes them once {:done} builds the websocket.
  defp handle_response({:data, _ref, data}, %{websocket: nil} = state) do
    %{state | pending: state.pending <> data}
  end

  defp handle_response(_other, state), do: state

  defp flush_pending(%{pending: ""} = state), do: state

  defp flush_pending(%{pending: data} = state) do
    decode_frames(%{state | pending: ""}, data)
  end

  defp decode_frames(state, data) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame/2)

      {:error, websocket, reason} ->
        Logger.warning("Slink: frame decode error: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  # Log every incoming frame when :verbose is set, then dispatch it.
  defp handle_frame(frame, %{verbose: true} = state) do
    log_frame(frame)
    dispatch_frame(frame, state)
  end

  defp handle_frame(frame, state), do: dispatch_frame(frame, state)

  defp log_frame({:text, text}), do: Logger.info("Slink: << text frame: #{text}")
  defp log_frame(frame), do: Logger.info("Slink: << frame: #{inspect(frame)}")

  defp dispatch_frame({:text, text}, state) do
    # A malformed frame from Slack must not take down the connection — skip it.
    case JSON.decode(text) do
      {:ok, message} ->
        safe_handle_message(message, state)

      {:error, _reason} ->
        Logger.warning("Slink: ignoring undecodable text frame")
        state
    end
  end

  defp dispatch_frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp dispatch_frame({:close, _code, _reason}, state), do: reconnect(state)
  defp dispatch_frame(_frame, state), do: state

  # Last line of defence: handling one message must never crash the socket. The
  # event path is built to be total (see `Slink.Event`, `Slink.Dispatcher`), so
  # this rescue should be unreachable — it's here so an unforeseen shape drops a
  # single message rather than the whole connection.
  defp safe_handle_message(message, state) do
    handle_message(message, state)
  rescue
    e ->
      Logger.error("Slink: dropping a message that raised while handling: #{inspect(e)}")
      state
  end

  ## Slack Socket Mode protocol messages

  defp handle_message(%{"type" => "hello"}, state) do
    Logger.debug("Slink: received hello")
    join_channels(state)
    # Slack accepted the connection — the next blip may retry fast again.
    %{state | backoff: 0}
  end

  defp handle_message(%{"type" => "disconnect", "reason" => reason}, state) do
    Logger.info("Slink: disconnect requested (#{reason}); reconnecting")
    reconnect(state)
  end

  defp handle_message(%{"envelope_id" => id} = message, state) when is_binary(id) do
    event = Event.from_socket_mode(message)
    context = %Context{transport: :socket_mode, bot_token: state.bot_token}

    if Dispatcher.sync_ack?(event) do
      # A modal submit: Slack wants the response in the ACK, so run the handler
      # now (bounded and isolated by ack_result/3) and ACK with its payload.
      ack(state, id, Dispatcher.ack_result(state.module, event, context))
    else
      # ACK first (within Slack's 3s window), then dispatch off-process. The ACK
      # advances the Mint connection state, so a raise from dispatch must not
      # unwind past it: `safe_handle_message/2`'s rescue would return the pre-ACK
      # state and leave the socket on a stale connection. Contain it here so the
      # post-ACK state is always what we return.
      state = ack(state, id)
      safe_dispatch(state.module, event, context)
      state
    end
  end

  defp handle_message(_message, state), do: state

  defp safe_dispatch(module, event, context) do
    Dispatcher.async(module, event, context)
  rescue
    e -> Logger.error("Slink: dropping a dispatch that raised after ack: #{inspect(e)}")
  end

  defp join_channels(%{join: []}), do: :ok

  defp join_channels(%{join: channels, bot_token: token}) do
    Task.Supervisor.start_child(Slink.TaskSupervisor, fn ->
      Enum.each(channels, fn channel ->
        case API.call(token, "conversations.join", %{channel: channel}) do
          {:ok, _} -> Logger.debug("Slink: joined #{channel}")
          {:error, reason} -> Logger.warning("Slink: join #{channel} failed: #{inspect(reason)}")
        end
      end)
    end)
  end

  defp ack(state, envelope_id, payload \\ %{})

  defp ack(state, envelope_id, payload) when map_size(payload) == 0 do
    send_frame(state, {:text, encode(%{envelope_id: envelope_id})})
  end

  defp ack(state, envelope_id, payload) do
    send_frame(state, {:text, encode(%{envelope_id: envelope_id, payload: payload})})
  end

  ## Sending

  defp send_frame(%{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <-
           Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        Logger.warning("Slink: encode error: #{inspect(reason)}")
        %{state | websocket: websocket}

      {:error, conn, reason} ->
        Logger.warning("Slink: send error: #{inspect(reason)}")
        reconnect(%{state | conn: conn})
    end
  end

  # Encodes an ACK frame. The envelope is our own (`%{envelope_id: binary}`), and
  # any handler-supplied `payload` was already checked for encodability by
  # `Dispatcher.ack_result/3`, so this cannot fail.
  defp encode(term), do: JSON.encode!(term)
end
