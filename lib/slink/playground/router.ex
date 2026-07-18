# Compiled only when the playground is enabled — see `Slink.Playground`.
if Application.compile_env(:slink, :playground, false) do
  defmodule Slink.Playground.Router do
    @moduledoc false
    # The playground's HTTP surface: the UI page and its SSE feed, the /ui/*
    # endpoints the browser posts interactions to, the fake Slack Web API under
    # /api/*, and the minted response_url / upload targets.

    use Plug.Router

    alias Slink.Playground.{Events, Workspace}

    plug(:match)
    plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON, pass: ["*/*"])
    plug(:dispatch)

    def call(conn, opts) do
      conn = put_private(conn, :playground_workspace, opts[:workspace])
      super(conn, opts)
    end

    get "/" do
      html = File.read!(Application.app_dir(:slink, "priv/playground/index.html"))

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, html)
    end

    # The live feed: a full workspace snapshot per change, as one SSE event.
    get "/events" do
      conn =
        conn
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      snapshot = Workspace.subscribe(workspace(conn))

      case chunk(conn, sse_frame(snapshot)) do
        {:ok, conn} -> sse_loop(conn)
        {:error, _closed} -> conn
      end
    end

    # The pre-signed upload target minted by files.getUploadURLExternal.
    post "/api/upload/:file_id" do
      {:ok, body, conn} = read_body(conn)

      case Workspace.record_upload(workspace(conn), file_id, byte_size(body)) do
        :ok -> send_resp(conn, 200, "OK")
        :error -> send_resp(conn, 404, "unknown file")
      end
    end

    # The fake Slack Web API — where `Slink.API.call/3` lands once the
    # playground has pointed :api_base_url at itself.
    post "/api/:method" do
      json(conn, Workspace.api_call(workspace(conn), method, conn.body_params))
    end

    # UI actions — each becomes a real event dispatched to the bot.
    post "/ui/message" do
      %{"channel" => channel, "text" => text} = conn.body_params
      :ok = Events.user_message(workspace(conn), channel, text, conn.body_params["thread_ts"])
      json(conn, %{"ok" => true})
    end

    post "/ui/slash" do
      %{"channel" => channel, "command" => command} = conn.body_params

      :ok =
        Events.slash_command(workspace(conn), channel, command, conn.body_params["text"] || "")

      json(conn, %{"ok" => true})
    end

    post "/ui/action" do
      %{"action" => action} = conn.body_params

      result =
        case conn.body_params do
          %{"source" => "home"} ->
            Events.view_action(workspace(conn), :home, action)

          %{"view_id" => view_id} ->
            Events.view_action(workspace(conn), view_id, action)

          %{"channel" => channel, "message_ts" => ts} ->
            Events.message_action(workspace(conn), channel, ts, action)
        end

      case result do
        :ok -> json(conn, %{"ok" => true})
        :error -> json(conn, %{"ok" => false, "error" => "not_found"})
      end
    end

    post "/ui/view_submission" do
      %{"view_id" => view_id, "values" => values} = conn.body_params

      case Events.submit_view(workspace(conn), view_id, values) do
        {:ok, ack} -> json(conn, %{"ok" => true, "ack" => ack})
        :error -> json(conn, %{"ok" => false, "error" => "not_found"})
      end
    end

    post "/ui/view_closed" do
      case Events.close_view(workspace(conn), conn.body_params["view_id"]) do
        :ok -> json(conn, %{"ok" => true})
        :error -> json(conn, %{"ok" => false, "error" => "not_found"})
      end
    end

    post "/ui/reaction" do
      %{"op" => op, "channel" => channel, "ts" => ts, "name" => name} = conn.body_params

      case Events.user_reaction(workspace(conn), op, channel, ts, name) do
        :ok -> json(conn, %{"ok" => true})
        {:error, reason} -> json(conn, %{"ok" => false, "error" => reason})
      end
    end

    post "/ui/home_opened" do
      :ok = Events.home_opened(workspace(conn))
      json(conn, %{"ok" => true})
    end

    post "/ui/redeliver" do
      case Events.redeliver(workspace(conn), conn.body_params["entry_id"]) do
        :ok -> json(conn, %{"ok" => true})
        {:error, reason} -> json(conn, %{"ok" => false, "error" => to_string(reason)})
        :error -> json(conn, %{"ok" => false, "error" => "not_found"})
      end
    end

    # The minted response_url target for slash commands and interactions.
    post "/respond/:token" do
      case Workspace.respond(workspace(conn), token, conn.body_params) do
        :unknown_token -> send_resp(conn, 404, "unknown response_url")
        reply -> json(conn, reply)
      end
    end

    match _ do
      send_resp(conn, 404, "not found")
    end

    defp sse_loop(conn) do
      result =
        receive do
          {:playground, :state, snapshot} -> chunk(conn, sse_frame(snapshot))
        after
          # Keep proxies and the browser from timing out an idle stream.
          15_000 -> chunk(conn, ": ping\n\n")
        end

      case result do
        {:ok, conn} -> sse_loop(conn)
        {:error, _closed} -> conn
      end
    end

    # JSON.encode!/1 never emits raw newlines, so one data: line is enough.
    defp sse_frame(json), do: "event: state\ndata: #{json}\n\n"

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(body))
    end

    defp workspace(conn), do: conn.private.playground_workspace
  end
end
