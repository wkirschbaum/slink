defmodule Slink.EventsApi.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @secret "8f742231b10e8888abcd99yyyzzz85a5"

  defmodule TestBot do
    use Slink

    @impl true
    def handle_event(event, _ctx) do
      # Report back to the test process registered under the event's channel.
      case Process.whereis(:plug_test_sink) do
        nil -> :ok
        pid -> send(pid, {:event, event})
      end

      :ok
    end
  end

  setup do
    Process.register(self(), :plug_test_sink)
    :ok
  end

  defp signed_conn(body, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:second))
    secret = Keyword.get(opts, :secret, @secret)
    basestring = "v0:#{timestamp}:#{body}"

    signature =
      "v0=" <> (:crypto.mac(:hmac, :sha256, secret, basestring) |> Base.encode16(case: :lower))

    conn(:post, "/slack/events", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-slack-request-timestamp", to_string(timestamp))
    |> put_req_header("x-slack-signature", signature)
  end

  defp opts do
    Slink.EventsApi.Plug.init(module: TestBot, signing_secret: @secret, bot_token: "xoxb-test")
  end

  test "answers the url_verification challenge" do
    body = JSON.encode!(%{type: "url_verification", challenge: "the-challenge"})
    conn = Slink.EventsApi.Plug.call(signed_conn(body), opts())

    assert conn.status == 200
    assert conn.resp_body == "the-challenge"
  end

  test "accepts a signed event_callback and dispatches it" do
    body =
      JSON.encode!(%{
        type: "event_callback",
        event: %{type: "app_mention", channel: "C1", user: "U1"}
      })

    conn = Slink.EventsApi.Plug.call(signed_conn(body), opts())

    assert conn.status == 200
    assert_receive {:event, %Slink.Event{type: "app_mention", transport: :http}}, 1_000
  end

  test "rejects a bad signature" do
    body = JSON.encode!(%{type: "event_callback", event: %{type: "message"}})
    conn = Slink.EventsApi.Plug.call(signed_conn(body, secret: "wrong-secret"), opts())

    assert conn.status == 401
    refute_receive {:event, _}, 200
  end

  test "rejects a stale timestamp (replay protection)" do
    body = JSON.encode!(%{type: "event_callback", event: %{type: "message"}})
    old = System.system_time(:second) - 3600
    conn = Slink.EventsApi.Plug.call(signed_conn(body, timestamp: old), opts())

    assert conn.status == 401
  end

  test "rejects a non-numeric timestamp" do
    body = JSON.encode!(%{type: "event_callback", event: %{type: "message"}})
    conn = Slink.EventsApi.Plug.call(signed_conn(body, timestamp: "not-a-number"), opts())

    assert conn.status == 401
  end

  test "returns 400 on a validly-signed but non-JSON body" do
    conn = Slink.EventsApi.Plug.call(signed_conn("this is not json"), opts())

    assert conn.status == 400
  end

  test "returns 413 when the body exceeds the size limit (never buffers unbounded)" do
    big_body = String.duplicate("x", 1_000_001)

    conn =
      conn(:post, "/slack/events", big_body)
      |> put_req_header("content-type", "application/json")

    conn = Slink.EventsApi.Plug.call(conn, opts())
    assert conn.status == 413
  end
end
