defmodule Slink.SocketModeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Slink.Test.FakeSlack

  defmodule Bot do
    use Slink

    @impl true
    def handle_event(event, context) do
      send(:socket_mode_sink, {:bot_event, event, context})
      :ok
    end
  end

  defmodule CrashBot do
    use Slink

    @impl true
    def handle_event(_event, _context), do: raise("handler boom")
  end

  setup do
    Process.register(self(), :socket_mode_sink)
    :ok
  end

  defp start_client(url, opts \\ []) do
    # name: nil → unregistered, so clients from adjacent tests never collide.
    start_supervised!(
      {Slink.SocketMode,
       Keyword.merge(
         [module: Bot, bot_token: "xoxb-test", name: nil, open_connection: fn -> {:ok, url} end],
         opts
       )}
    )
  end

  test "full round trip: connect, receive hello + event, dispatch, and ACK" do
    {:ok, url, server} = FakeSlack.start(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    start_client(url)

    assert_receive {:fake_slack, :connected}, 15_000

    assert_receive {:bot_event, %Slink.Event{} = event, context}, 15_000
    assert event.type == "app_mention"
    assert event.transport == :socket_mode
    assert event.envelope_id == "env-1"
    assert event.payload["channel"] == "C1"
    assert context == %Slink.Context{transport: :socket_mode, bot_token: "xoxb-test"}

    assert_receive {:fake_slack, :frame, ack}, 15_000
    assert JSON.decode!(ack) == %{"envelope_id" => "env-1"}
  end

  test "verbose: true logs every incoming frame" do
    {:ok, url, server} = FakeSlack.start(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    log =
      capture_log(fn ->
        start_client(url, verbose: true)
        assert_receive {:bot_event, _event, _context}, 15_000
      end)

    assert log =~ "Slink: << text frame:"
    # The raw JSON is logged, so the event payload is visible.
    assert log =~ "app_mention"
  end

  test "verbose defaults to off — frames are not logged" do
    {:ok, url, server} = FakeSlack.start(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    log =
      capture_log(fn ->
        start_client(url)
        assert_receive {:bot_event, _event, _context}, 15_000
      end)

    refute log =~ "Slink: << text frame:"
  end

  test "joins configured channels once connected" do
    {:ok, api_url, api} = Slink.Test.FakeWebApi.start()
    Application.put_env(:slink, :api_base_url, api_url)
    Application.put_env(:slink, :test_api_sink, self())

    on_exit(fn ->
      Application.delete_env(:slink, :api_base_url)
      Application.delete_env(:slink, :test_api_sink)
      Process.exit(api, :normal)
    end)

    {:ok, url, server} = FakeSlack.start(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    start_client(url, bot_token: "xoxb-join", join: ["C100", "C200"])

    assert_receive {:api_request, "/conversations.join", %{"channel" => "C100"}}, 15_000
    assert_receive {:api_request, "/conversations.join", %{"channel" => "C200"}}, 15_000
  end

  test "replies to a server ping with a pong" do
    {:ok, url, server} = FakeSlack.start(self(), frames: FakeSlack.ping_frames("ping-payload"))
    on_exit(fn -> Process.exit(server, :normal) end)

    start_client(url)

    assert_receive {:fake_slack, :connected}, 15_000
    assert_receive {:fake_slack, :pong, "ping-payload"}, 15_000
  end

  test "reconnects when Slack sends a disconnect message" do
    # Disconnect on the first connection, behave normally on the reconnect.
    {:ok, url, server} =
      FakeSlack.start(self(), first_frames: FakeSlack.disconnect_frames())

    on_exit(fn -> Process.exit(server, :normal) end)

    start_client(url)

    assert_receive {:fake_slack, :connected}, 15_000
    # A second connect proves the client reconnected after the disconnect frame.
    assert_receive {:fake_slack, :connected}, 15_000
  end

  test "reconnects after the server cleanly closes the socket" do
    # Close the first connection right after connecting, then behave normally.
    {:ok, url, server} = FakeSlack.start(self(), first_frames: [], close_first: true)
    on_exit(fn -> Process.exit(server, :normal) end)

    start_client(url)

    assert_receive {:fake_slack, :connected}, 15_000
    assert_receive {:fake_slack, :connected}, 15_000
  end

  test "recovers when the WebSocket handshake fails (non-101 response)" do
    {:ok, url, server} = FakeSlack.start(self(), mode: :plain)
    on_exit(fn -> Process.exit(server, :normal) end)

    start_client(url)

    # Plain HTTP response → Mint.WebSocket.new/4 fails → reconnect attempt.
    assert_receive {:fake_slack, :upgrade_attempt}, 15_000
    assert_receive {:fake_slack, :upgrade_attempt}, 15_000
  end

  test "ignores binary frames and non-envelope control messages, still ACKs real events" do
    frames = [
      {:text, JSON.encode!(%{"type" => "goodbye"})},
      {:binary, "not for us"},
      FakeSlack.envelope_frame()
    ]

    {:ok, url, server} = FakeSlack.start(self(), frames: frames)
    on_exit(fn -> Process.exit(server, :normal) end)

    start_client(url)

    # Despite the junk frames, the real envelope is still handled and ACKed.
    assert_receive {:bot_event, %Slink.Event{type: "app_mention"}, _context}, 15_000
    assert_receive {:fake_slack, :frame, ack}, 15_000
    assert JSON.decode!(ack) == %{"envelope_id" => "env-1"}
  end

  test "handles a connection URL that carries a query string" do
    {:ok, url, server} = FakeSlack.start(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    start_client(url, open_connection: fn -> {:ok, url <> "?ticket=abc123"} end)

    assert_receive {:fake_slack, :connected}, 15_000
    assert_receive {:bot_event, _event, _context}, 15_000
  end

  test "a crashing handler does not take down the socket (still ACKs, stays alive)" do
    {:ok, url, server} = FakeSlack.start(self())
    on_exit(fn -> Process.exit(server, :normal) end)

    capture_log(fn ->
      pid = start_client(url, module: CrashBot)
      # ACK is sent before dispatch, so it lands even though the handler raises.
      assert_receive {:fake_slack, :frame, ack}, 15_000
      assert JSON.decode!(ack) == %{"envelope_id" => "env-1"}
      Process.sleep(100)
      assert Process.alive?(pid)
    end)
  end

  test "a malformed text frame is skipped, not fatal — later events still flow" do
    frames = [{:text, "{ this is not json"}, FakeSlack.envelope_frame()]
    {:ok, url, server} = FakeSlack.start(self(), frames: frames)
    on_exit(fn -> Process.exit(server, :normal) end)

    capture_log(fn ->
      start_client(url)
      # The bad frame is ignored and the following real envelope is dispatched.
      assert_receive {:bot_event, %Slink.Event{type: "app_mention"}, _context}, 15_000
    end)
  end

  test "handles an abrupt transport failure without crashing" do
    {:ok, url, server} = FakeSlack.start(self())
    pid = start_client(url)

    assert_receive {:fake_slack, :connected}, 15_000
    # Kill the server hard → client sees a transport error and schedules a reconnect.
    # Unlink first: :kill on a linked process would otherwise propagate to us.
    Process.unlink(server)
    Process.exit(server, :kill)
    Process.sleep(100)
    assert Process.alive?(pid)
  end

  test "ignores stray transport-shaped messages once connected" do
    {:ok, url, server} = FakeSlack.start(self())
    on_exit(fn -> Process.exit(server, :normal) end)
    pid = start_client(url)

    assert_receive {:fake_slack, :connected}, 15_000
    # A message that isn't for our socket → Mint returns :unknown → ignored.
    send(pid, {:tcp, :not_my_socket, "garbage"})
    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "derives http scheme and default port from a portless ws:// URL" do
    # Connection to :80 will fail, but the scheme/port derivation runs first.
    pid = start_client("unused", open_connection: fn -> {:ok, "ws://127.0.0.1/link"} end)
    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "derives https scheme and default port from a portless wss:// URL" do
    pid = start_client("unused", open_connection: fn -> {:ok, "wss://127.0.0.1/link"} end)
    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "recovers from an abrupt transport drop (no close frame)" do
    {:ok, url} = Slink.Test.RogueServer.start(self(), :drop)
    pid = start_client(url)

    assert_receive {:rogue, :connected}, 15_000
    # The raw socket close surfaces as a transport error; the client stays up.
    Process.sleep(100)
    assert Process.alive?(pid)
  end

  test "uses apps.connections.open by default when no :open_connection is given" do
    {:ok, api_url, api} = Slink.Test.FakeWebApi.start()
    Application.put_env(:slink, :api_base_url, api_url)

    on_exit(fn ->
      Application.delete_env(:slink, :api_base_url)
      Process.exit(api, :normal)
    end)

    # No :open_connection override → the default path calls the Web API, which
    # returns a URL that won't connect; the client should retry, not crash.
    pid = start_supervised!({Slink.SocketMode, module: Bot, app_token: "xapp-test", name: nil})
    Process.sleep(100)
    assert Process.alive?(pid)
  end

  test "survives when opening the connection URL fails, and ignores stray messages" do
    pid = start_client("ws://unused", open_connection: fn -> {:error, :boom} end)

    # No crash: the process stays up and schedules a retry.
    send(pid, :some_unexpected_message)
    Process.sleep(50)
    assert Process.alive?(pid)
  end
end
