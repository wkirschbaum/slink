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
      body = json(conn.path_info)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(body))
    end

    # Optional observability: if a test registered a sink pid, forward requests.
    defp report(path_info, raw) do
      case Application.get_env(:slink, :test_api_sink) do
        pid when is_pid(pid) ->
          params = with {:ok, map} <- JSON.decode(raw), do: map, else: (_ -> raw)
          send(pid, {:api_request, "/" <> Enum.join(path_info, "/"), params})

        _ ->
          :ok
      end
    end

    # Slack always returns HTTP 200; success/failure lives in the "ok" field.
    defp json(["apps.connections.open"]), do: %{"ok" => true, "url" => "wss://example/link"}
    defp json(["chat.postMessage"]), do: %{"ok" => true, "channel" => "C1", "ts" => "1.2"}
    defp json(["conversations.join"]), do: %{"ok" => true, "channel" => %{"id" => "C1"}}
    defp json(["boom.method"]), do: %{"ok" => false, "error" => "not_authed"}
    # A malformed response missing the "ok" field entirely.
    defp json(["weird.method"]), do: %{"unexpected" => true}
    defp json(_), do: %{"ok" => false, "error" => "unknown_method"}
  end
end
