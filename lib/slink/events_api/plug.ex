defmodule Slink.EventsApi.Plug do
  @moduledoc """
  Events API transport: a `Plug` that receives Slack's HTTP event callbacks.

  It verifies Slack's request signature, answers the `url_verification`
  challenge, responds `200` immediately, and dispatches the event off-process
  (so your handler can't blow Slack's ~3s response budget).

  Mount it in a router:

      forward "/slack/events", to: Slink.EventsApi.Plug,
        init_opts: [
          module: MyBot,
          signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
          bot_token: System.fetch_env!("SLACK_BOT_TOKEN")
        ]

  Or run it standalone with Bandit:

      Bandit.start_link(
        plug: {Slink.EventsApi.Plug,
               module: MyBot,
               signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
               bot_token: System.fetch_env!("SLACK_BOT_TOKEN")},
        port: 4000
      )

  Options:

    * `:module` (required) — a module implementing the `Slink` behaviour.
    * `:signing_secret` (required) — the app's Signing Secret, for request verification.
    * `:bot_token` — bot token (`xoxb-…`) passed to handlers for Web API calls.

  > #### Slash commands & interactivity {: .info}
  > Those payloads arrive `application/x-www-form-urlencoded`, not JSON. This
  > plug handles the JSON Events API. Decode `x-www-form-urlencoded` bodies
  > (the `payload` field holds JSON) before reaching here to support them.
  """

  @behaviour Plug
  import Plug.Conn

  alias Slink.{Dispatcher, Event}

  # Slack signs requests as v0=HMAC-SHA256(signing_secret, "v0:<ts>:<raw body>").
  @max_skew_seconds 300
  @max_body_bytes 1_000_000

  @impl true
  def init(opts) do
    %{
      module: Keyword.fetch!(opts, :module),
      signing_secret: Keyword.fetch!(opts, :signing_secret),
      bot_token: Keyword.get(opts, :bot_token)
    }
  end

  @impl true
  def call(conn, opts) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} ->
        if verified?(conn, body, opts.signing_secret) do
          respond(conn, body, opts)
        else
          conn |> send_resp(401, "invalid signature") |> halt()
        end

      # Body exceeded @max_body_bytes, or the socket errored — reject, don't raise.
      {:more, _partial, conn} ->
        conn |> send_resp(413, "payload too large") |> halt()

      {:error, _reason} ->
        conn |> send_resp(400, "bad request") |> halt()
    end
  end

  defp respond(conn, body, opts) do
    case JSON.decode(body) do
      {:ok, %{"type" => "url_verification", "challenge" => challenge}} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, challenge)
        |> halt()

      {:ok, params} ->
        event = Event.from_http(params)
        context = %Slink.Context{transport: :http, bot_token: opts.bot_token}
        Dispatcher.async(opts.module, event, context)

        conn |> send_resp(200, "") |> halt()

      {:error, _reason} ->
        conn |> send_resp(400, "bad request") |> halt()
    end
  end

  defp verified?(conn, body, secret) do
    with [timestamp] <- get_req_header(conn, "x-slack-request-timestamp"),
         [signature] <- get_req_header(conn, "x-slack-signature"),
         true <- fresh?(timestamp) do
      basestring = "v0:#{timestamp}:#{body}"

      expected =
        "v0=" <>
          (:crypto.mac(:hmac, :sha256, secret, basestring) |> Base.encode16(case: :lower))

      Plug.Crypto.secure_compare(expected, signature)
    else
      _ -> false
    end
  end

  defp fresh?(timestamp) do
    case Integer.parse(timestamp) do
      {seconds, _rest} -> abs(System.system_time(:second) - seconds) <= @max_skew_seconds
      :error -> false
    end
  end
end
