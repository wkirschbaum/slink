defmodule Slink.EventsApi.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @secret "8f742231b10e8888abcd99yyyzzz85a5"

  defmodule TestBot do
    use Slink

    @impl true
    def handle_event(event, _context) do
      # Report back to the test process registered under the event's channel.
      case Process.whereis(:plug_test_sink) do
        nil -> :ok
        pid -> send(pid, {:event, event})
      end

      :ok
    end
  end

  # Answers a modal submit synchronously with a `response_action`.
  defmodule AckBot do
    use Slink

    @impl true
    def handle_event(%Slink.Event{type: :view_submission}, _context) do
      {:ack, %{response_action: "errors", errors: %{"block" => "nope"}}}
    end

    def handle_event(_event, _context), do: :ok
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
    |> put_req_header("content-type", Keyword.get(opts, :content_type, "application/json"))
    |> put_req_header("x-slack-request-timestamp", to_string(timestamp))
    |> put_req_header("x-slack-signature", signature)
  end

  # A signed `application/x-www-form-urlencoded` request (slash / interactivity).
  defp signed_form(params) do
    signed_conn(URI.encode_query(params), content_type: "application/x-www-form-urlencoded")
  end

  defp opts(module \\ TestBot) do
    Slink.EventsApi.Plug.init(module: module, signing_secret: @secret, bot_token: "xoxb-test")
  end

  # Reports the context so tests can assert on the resolved bot token.
  defmodule ContextBot do
    use Slink

    @impl true
    def handle_event(_event, context) do
      send(:plug_test_sink, {:ctx, context})
      :ok
    end
  end

  test "accepts signing_secret and bot_token as 0-arity functions" do
    # Phoenix `forward` evaluates init options at compile time in prod; functions
    # defer the env read to runtime and are resolved per request.
    opts =
      Slink.EventsApi.Plug.init(
        module: ContextBot,
        signing_secret: fn -> @secret end,
        bot_token: fn -> "xoxb-lazy" end
      )

    body = JSON.encode!(%{type: "event_callback", event: %{type: "app_mention"}})
    conn = Slink.EventsApi.Plug.call(signed_conn(body), opts)

    assert conn.status == 200
    assert_receive {:ctx, %Slink.Context{bot_token: "xoxb-lazy"}}, 1_000
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
    assert_receive {:event, %Slink.Event{type: :app_mention, transport: :http}}, 1_000
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

  test "decodes a form-encoded slash command and dispatches it" do
    conn =
      Slink.EventsApi.Plug.call(
        signed_form(%{"command" => "/slink", "text" => "hi", "channel_id" => "C1"}),
        opts()
      )

    assert conn.status == 200
    assert_receive {:event, %Slink.Event{type: :slash_commands, kind: :slash_commands}}, 1_000
  end

  test "decodes a form-encoded interaction (payload field) and dispatches it" do
    payload = JSON.encode!(%{"type" => "block_actions", "trigger_id" => "T1"})
    conn = Slink.EventsApi.Plug.call(signed_form(%{"payload" => payload}), opts())

    assert conn.status == 200
    assert_receive {:event, %Slink.Event{type: :block_actions, kind: :interactive}}, 1_000
  end

  test "answers a view_submission synchronously with the handler's response_action" do
    payload = JSON.encode!(%{"type" => "view_submission", "view" => %{"callback_id" => "m"}})
    conn = Slink.EventsApi.Plug.call(signed_form(%{"payload" => payload}), opts(AckBot))

    assert conn.status == 200

    assert JSON.decode!(conn.resp_body) == %{
             "response_action" => "errors",
             "errors" => %{"block" => "nope"}
           }
  end

  test "a view_submission with no ack payload closes the modal (empty 200)" do
    # TestBot returns :ok, so there's no response_action — an empty body closes it.
    payload = JSON.encode!(%{"type" => "view_submission", "view" => %{"callback_id" => "m"}})
    conn = Slink.EventsApi.Plug.call(signed_form(%{"payload" => payload}), opts())

    assert conn.status == 200
    assert conn.resp_body == ""
  end
end
