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

  ## Slash commands & interactivity

  Slack delivers those as `application/x-www-form-urlencoded`, not JSON; this
  plug decodes both. Point the app's **Request URL** for *Interactivity* and
  *Slash Commands* at this same endpoint. Slash commands and most interactions
  are handled off-process like events, and your handler replies via the
  `response_url` (see `Slink.reply/3`).

  The one exception is `view_submission` (a modal submit): Slack expects a
  `response_action` in the immediate reply. For that type the handler runs
  synchronously and its `{:ack, map}` return is sent back as the response — so
  keep it fast (Slack's window is ~3s). Returning anything else closes the modal.
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

  # Slash commands and interactions arrive form-encoded; events arrive as JSON.
  defp respond(conn, body, opts) do
    if form?(conn) do
      handle(conn, decode_form(body), opts, &Event.from_http_form/1)
    else
      respond_json(conn, body, opts)
    end
  end

  defp respond_json(conn, body, opts) do
    case JSON.decode(body) do
      {:ok, %{"type" => "url_verification", "challenge" => challenge}} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, challenge)
        |> halt()

      {:ok, params} ->
        handle(conn, with_retry(conn, params), opts, &Event.from_http/1)

      {:error, _reason} ->
        conn |> send_resp(400, "bad request") |> halt()
    end
  end

  # One path for every payload: build the event, then either fold a synchronous
  # response into the reply (view_submission) or ACK now and dispatch off-process.
  defp handle(conn, params, opts, normalize) do
    event = normalize.(params)
    context = %Slink.Context{transport: :http, bot_token: opts.bot_token}

    if Dispatcher.sync_ack?(event) do
      ack_response(conn, Dispatcher.ack_result(opts.module, event, context))
    else
      Dispatcher.async(opts.module, event, context)
      conn |> send_resp(200, "") |> halt()
    end
  end

  # An empty ACK closes the modal; a payload (e.g. `response_action: "errors"`)
  # controls it. Slack reads a JSON body here, so set the content type.
  defp ack_response(conn, payload) when map_size(payload) == 0 do
    conn |> send_resp(200, "") |> halt()
  end

  defp ack_response(conn, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(payload))
    |> halt()
  end

  defp form?(conn) do
    case get_req_header(conn, "content-type") do
      [ct | _] -> String.contains?(ct, "application/x-www-form-urlencoded")
      _ -> false
    end
  end

  defp decode_form(body), do: URI.decode_query(body)

  # Surface Slack's retry counter (a header) in the body so `Event.retry?/1`
  # works over HTTP the way it does for Socket Mode's envelope field.
  defp with_retry(conn, params) when is_map(params) do
    with [n | _] <- get_req_header(conn, "x-slack-retry-num"),
         {num, _} <- Integer.parse(n) do
      Map.put(params, "retry_num", num)
    else
      _ -> params
    end
  end

  defp with_retry(_conn, params), do: params

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
