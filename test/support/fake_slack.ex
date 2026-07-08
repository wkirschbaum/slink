defmodule Slink.Test.FakeSlack do
  @moduledoc """
  A minimal, scriptable Slack Socket Mode server for tests.

  Stands up a real WebSocket endpoint (Bandit + WebSockAdapter) that behaves
  like Slack, letting us exercise the entire `Mint.WebSocket` client path
  without a real workspace.

  `start/2` options:

    * `:frames` — frames to push once the client connects. Defaults to a `hello`
      followed by an `app_mention` `events_api` envelope (id `"env-1"`).
    * `:mode` — `:websocket` (default) or `:plain` to answer the upgrade with a
      non-WebSocket 200, so we can test the client's handshake-failure path.
    * `:close_after` — when true, cleanly close the socket (normal stop, code
      1000) right after pushing `:frames`, exercising the client's close path.

  Messages sent to `test_pid`:

    * `{:fake_slack, :connected}` — a client completed the upgrade
    * `{:fake_slack, :upgrade_attempt}` — a client hit the server in `:plain` mode
    * `{:fake_slack, :frame, text}` — the client sent a text frame (e.g. an ACK)
    * `{:fake_slack, :pong, data}` — the client replied to a ping
  """

  @default_frames [
    {:text, JSON.encode!(%{"type" => "hello"})},
    {:text,
     JSON.encode!(%{
       "type" => "events_api",
       "envelope_id" => "env-1",
       "payload" => %{
         "type" => "event_callback",
         "event" => %{"type" => "app_mention", "channel" => "C1", "user" => "U1"}
       }
     })}
  ]

  @doc """
  Start the server on a free loopback port. Returns `{:ok, ws_url, pid}`.

  Options:

    * `:frames` — frames pushed on every connection (default: `hello` + envelope).
    * `:first_frames` — frames pushed on the *first* connection only (defaults to
      `:frames`). Use this to misbehave once then recover, avoiding reconnect storms.
    * `:close_first` — cleanly close the socket right after the first connection.
    * `:mode` — `:websocket` (default) or `:plain`.
  """
  def start(test_pid, opts \\ []) do
    # A shared counter so the Socket handler knows which connection it is.
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    frames = Keyword.get(opts, :frames, @default_frames)

    plug_opts = [
      test_pid: test_pid,
      counter: counter,
      frames: frames,
      first_frames: Keyword.get(opts, :first_frames, frames),
      close_first: Keyword.get(opts, :close_first, false),
      mode: Keyword.get(opts, :mode, :websocket)
    ]

    {:ok, pid} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, plug_opts},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        # One acceptor is plenty for a test server; 100 (the default) creates
        # needless scheduler pressure across many concurrent test servers.
        thousand_island_options: [num_acceptors: 1]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, "ws://127.0.0.1:#{port}/link", pid}
  end

  @doc "The default frames pushed on connect: a `hello` and an `app_mention` envelope."
  def default_frames, do: @default_frames

  @doc "A single `app_mention` `events_api` envelope frame (id `env-1`)."
  def envelope_frame, do: List.last(@default_frames)

  @doc "Frames that push a Socket Mode `disconnect` request."
  def disconnect_frames(reason \\ "refresh_requested") do
    [{:text, JSON.encode!(%{"type" => "disconnect", "reason" => reason})}]
  end

  @doc "Frames that push a WebSocket ping the client must pong."
  def ping_frames(payload \\ "hi"), do: [{:ping, payload}]

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug
    import Elixir.Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      case Keyword.fetch!(opts, :mode) do
        :plain ->
          send(Keyword.fetch!(opts, :test_pid), {:fake_slack, :upgrade_attempt})
          send_resp(conn, 200, "not a websocket")

        :websocket ->
          conn
          |> WebSockAdapter.upgrade(Slink.Test.FakeSlack.Socket, opts, timeout: 60_000)
          |> halt()
      end
    end
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      n = Agent.get_and_update(Keyword.fetch!(opts, :counter), &{&1, &1 + 1})
      first? = n == 0

      send(test_pid, {:fake_slack, :connected})
      if first? and Keyword.fetch!(opts, :close_first), do: send(self(), :__close)

      frames =
        if first?, do: Keyword.fetch!(opts, :first_frames), else: Keyword.fetch!(opts, :frames)

      {:push, frames, %{test_pid: test_pid}}
    end

    @impl true
    def handle_in({text, [opcode: :text]}, state) do
      send(state.test_pid, {:fake_slack, :frame, text})
      {:ok, state}
    end

    def handle_in(_other, state), do: {:ok, state}

    @impl true
    def handle_control({data, [opcode: :pong]}, state) do
      send(state.test_pid, {:fake_slack, :pong, data})
      {:ok, state}
    end

    def handle_control(_other, state), do: {:ok, state}

    @impl true
    def handle_info(:__close, state), do: {:stop, :normal, state}
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
