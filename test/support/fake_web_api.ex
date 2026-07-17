defmodule Slink.Test.FakeWebApi do
  @moduledoc """
  A tiny stand-in for Slack's Web API (`https://slack.com/api`) for tests.

  Start it, point `config :slink, :api_base_url` at the returned URL, and it
  answers a handful of methods the way Slack does — including the quirk that
  logical failures still come back as HTTP 200 with `"ok" => false`.
  """

  @doc "Start on a free loopback port. Returns `{:ok, base_url, pid}`."
  def start do
    {:ok, pid} =
      Bandit.start_link(
        plug: __MODULE__.Plug,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        thousand_island_options: [num_acceptors: 1]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, "http://127.0.0.1:#{port}", pid}
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug
    import Elixir.Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      report(conn.path_info, raw)
      respond(conn, conn.path_info)
    end

    # One method always rate-limits (HTTP 429 + Retry-After) so tests can prove
    # `Slink.API.call/3` backs off and retries on 429.
    defp respond(conn, ["rate.limited"]) do
      conn
      |> put_resp_header("retry-after", "0")
      |> put_resp_content_type("application/json")
      |> send_resp(429, JSON.encode!(%{"error" => "ratelimited"}))
    end

    # The external upload flow: hand out an upload URL pointing back at this
    # server, accept the bytes there.
    defp respond(conn, ["files.getUploadURLExternal"]) do
      body = %{
        "ok" => true,
        "upload_url" => "http://127.0.0.1:#{conn.port}/upload/bytes",
        "file_id" => "F1"
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(body))
    end

    defp respond(conn, ["upload", "bytes"]), do: send_resp(conn, 200, "OK")

    defp respond(conn, path) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(json(path)))
    end

    # Optional observability: if a test registered a sink pid, forward requests.
    # Bodies are JSON for Web API methods, form-encoded for oauth.v2.access and
    # files.getUploadURLExternal, and raw bytes for the upload endpoint.
    defp report(path_info, raw) do
      case Application.get_env(:slink, :test_api_sink) do
        pid when is_pid(pid) ->
          send(pid, {:api_request, "/" <> Enum.join(path_info, "/"), decode(path_info, raw)})

        _ ->
          :ok
      end
    end

    defp decode(["upload", "bytes"], raw), do: raw

    defp decode(_path, raw) do
      case JSON.decode(raw) do
        {:ok, map} -> map
        _ -> URI.decode_query(raw)
      end
    end

    # Slack always returns HTTP 200; success/failure lives in the "ok" field.
    defp json(["apps.connections.open"]), do: %{"ok" => true, "url" => "wss://example/link"}
    defp json(["chat.postMessage"]), do: %{"ok" => true, "channel" => "C1", "ts" => "1.2"}
    defp json(["chat.update"]), do: %{"ok" => true, "channel" => "C1", "ts" => "1.2"}
    defp json(["chat.delete"]), do: %{"ok" => true, "channel" => "C1", "ts" => "1.2"}
    defp json(["chat.postEphemeral"]), do: %{"ok" => true, "message_ts" => "1.2"}
    defp json(["chat.getPermalink"]), do: %{"ok" => true, "permalink" => "https://slack/p1"}
    defp json(["conversations.join"]), do: %{"ok" => true, "channel" => %{"id" => "C1"}}
    defp json(["conversations.open"]), do: %{"ok" => true, "channel" => %{"id" => "D1"}}

    defp json(["conversations.history"]),
      do: %{"ok" => true, "messages" => [], "response_metadata" => %{"next_cursor" => ""}}

    defp json(["chat.scheduleMessage"]), do: %{"ok" => true, "scheduled_message_id" => "Q1"}

    defp json(["files.completeUploadExternal"]),
      do: %{"ok" => true, "files" => [%{"id" => "F1", "title" => "report"}]}

    defp json(["auth.test"]),
      do: %{"ok" => true, "user_id" => "U-BOT", "team_id" => "T1", "team" => "Acme"}

    defp json(["assistant.threads.setStatus"]), do: %{"ok" => true}
    defp json(["assistant.threads.setTitle"]), do: %{"ok" => true}
    defp json(["assistant.threads.setSuggestedPrompts"]), do: %{"ok" => true}
    defp json(["chat.startStream"]), do: %{"ok" => true, "channel" => "D1", "ts" => "9.1"}
    defp json(["chat.appendStream"]), do: %{"ok" => true, "channel" => "D1", "ts" => "9.1"}
    defp json(["chat.stopStream"]), do: %{"ok" => true, "channel" => "D1", "ts" => "9.1"}

    defp json(["oauth.v2.access"]) do
      %{
        "ok" => true,
        "access_token" => "xoxb-installed-secret",
        "token_type" => "bot",
        "bot_user_id" => "U-BOT",
        "app_id" => "A1",
        "team" => %{"id" => "T-NEW", "name" => "Acme"},
        "enterprise" => nil,
        "authed_user" => %{"id" => "U-INSTALLER"}
      }
    end

    defp json(["users.info"]), do: %{"ok" => true, "user" => %{"id" => "U1", "name" => "alice"}}
    defp json(["reactions.add"]), do: %{"ok" => true}
    defp json(["reactions.remove"]), do: %{"ok" => true}
    defp json(["views.open"]), do: %{"ok" => true, "view" => %{"id" => "V1"}}
    defp json(["views.update"]), do: %{"ok" => true, "view" => %{"id" => "V1"}}
    defp json(["views.push"]), do: %{"ok" => true, "view" => %{"id" => "V2"}}
    defp json(["views.publish"]), do: %{"ok" => true}
    # A slash command / interaction `response_url` post lands here.
    defp json(["response"]), do: %{"ok" => true}
    defp json(["boom.method"]), do: %{"ok" => false, "error" => "not_authed"}
    # A malformed response missing the "ok" field entirely.
    defp json(["weird.method"]), do: %{"unexpected" => true}
    defp json(_), do: %{"ok" => false, "error" => "unknown_method"}
  end
end
