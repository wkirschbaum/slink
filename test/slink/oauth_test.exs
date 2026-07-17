defmodule Slink.OAuthTest do
  # async: false — sets shared app env (api_base_url, test_api_sink).
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Plug.Test

  alias Slink.OAuth

  setup do
    {:ok, base_url, pid} = Slink.Test.FakeWebApi.start()
    Application.put_env(:slink, :api_base_url, base_url)
    Application.put_env(:slink, :test_api_sink, self())

    on_exit(fn ->
      Application.delete_env(:slink, :api_base_url)
      Application.delete_env(:slink, :test_api_sink)
      Process.exit(pid, :normal)
    end)

    :ok
  end

  describe "authorize_url/1" do
    test "builds the consent URL with joined scopes, redirect and state" do
      url =
        OAuth.authorize_url(
          client_id: "1.2",
          scopes: ~w(chat:write commands),
          redirect_uri: "https://example.com/cb",
          state: "s-1"
        )

      assert %URI{host: "slack.com", path: "/oauth/v2/authorize", query: query} = URI.parse(url)

      assert URI.decode_query(query) == %{
               "client_id" => "1.2",
               "scope" => "chat:write,commands",
               "redirect_uri" => "https://example.com/cb",
               "state" => "s-1"
             }
    end

    test "omits absent options and accepts a comma-string of scopes" do
      url = OAuth.authorize_url(client_id: "1.2", scopes: "chat:write,commands")
      query = URI.decode_query(URI.parse(url).query)

      assert query == %{"client_id" => "1.2", "scope" => "chat:write,commands"}
    end
  end

  describe "exchange/2" do
    test "exchanges the code (form-encoded) and normalises the install" do
      assert {:ok, install} =
               OAuth.exchange("code-123",
                 client_id: "1.2",
                 # A 0-arity secret is resolved, like the events plug's options.
                 client_secret: fn -> "shhh" end,
                 redirect_uri: "https://example.com/cb"
               )

      assert %OAuth.Install{
               team_id: "T-NEW",
               team_name: "Acme",
               bot_token: "xoxb-installed-secret",
               bot_user_id: "U-BOT",
               app_id: "A1",
               authed_user_id: "U-INSTALLER",
               enterprise_id: nil
             } = install

      assert_receive {:api_request, "/oauth.v2.access", params}, 1_000

      assert params["client_id"] == "1.2"
      assert params["client_secret"] == "shhh"
      assert params["code"] == "code-123"
      assert params["redirect_uri"] == "https://example.com/cb"
    end

    test "propagates a transport failure" do
      Application.put_env(:slink, :api_base_url, "http://127.0.0.1:1")

      assert {:error, _reason} =
               OAuth.exchange("code-123", client_id: "1.2", client_secret: "shhh")
    end

    test "the install's bot token is redacted from inspect output" do
      assert {:ok, install} =
               OAuth.exchange("code-123", client_id: "1.2", client_secret: "shhh")

      refute inspect(install, limit: :infinity) =~ "xoxb-installed-secret"
    end
  end

  describe "Slink.OAuth.Plug" do
    defp plug_opts(extra \\ []) do
      test_pid = self()

      Slink.OAuth.Plug.init(
        [
          client_id: "1.2",
          client_secret: "shhh",
          install: fn install ->
            send(test_pid, {:installed, install})
            :ok
          end
        ] ++ extra
      )
    end

    defp callback(query, opts) do
      Slink.OAuth.Plug.call(conn(:get, "/slack/oauth/callback?#{query}"), opts)
    end

    test "exchanges the code and hands the install to the callback" do
      conn = callback("code=abc", plug_opts())

      assert conn.status == 200
      assert conn.resp_body =~ "installed"
      assert_receive {:installed, %OAuth.Install{team_id: "T-NEW"}}, 1_000
    end

    test "redirects after success when :redirect_to is set" do
      conn = callback("code=abc", plug_opts(redirect_to: "https://example.com/done"))

      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "location") == ["https://example.com/done"]
      assert_receive {:installed, _}, 1_000
    end

    test "a cancelled consent (error param) is a friendly no-op" do
      conn = callback("error=access_denied", plug_opts())

      assert conn.status == 200
      assert conn.resp_body =~ "cancelled"
      refute_receive {:installed, _}, 200
    end

    test "a missing code is a 400" do
      assert callback("", plug_opts()).status == 400
    end

    test ":verify_state gates the callback" do
      opts = plug_opts(verify_state: fn state -> state == "expected" end)

      assert callback("code=abc&state=forged", opts).status == 403
      refute_receive {:installed, _}, 200

      assert callback("code=abc&state=expected", opts).status == 200
      assert_receive {:installed, _}, 1_000
    end

    test "a crashing install callback is a 500 with no secrets in the log" do
      opts =
        plug_opts()
        |> Map.put(:install, fn install ->
          # A store blowing up mid-save: the raised error embeds the token.
          raise "could not save #{install.bot_token}"
        end)

      log =
        capture_log(fn ->
          assert callback("code=abc", opts).status == 500
        end)

      assert log =~ "raised"
      refute log =~ "xoxb-installed-secret"
    end

    test "an install callback returning {:error, _} is a 500, reason not logged" do
      opts =
        plug_opts()
        |> Map.put(:install, fn install -> {:error, {:save_failed, install.bot_token}} end)

      log =
        capture_log(fn ->
          assert callback("code=abc", opts).status == 500
        end)

      assert log =~ "expected :ok"
      refute log =~ "xoxb-installed-secret"
    end

    test "a client_secret function that raises fails the request cleanly (502), secret-free log" do
      opts = plug_opts() |> Map.put(:client_secret, fn -> raise "SECRET_ENV not set" end)

      log =
        capture_log(fn ->
          assert callback("code=abc", opts).status == 502
        end)

      assert log =~ "raised"
      refute_receive {:installed, _}, 200
    end

    test "a malformed query string is a 400, not a crash" do
      # %C0 percent-decodes to an invalid UTF-8 byte, which raises in
      # fetch_query_params; the plug must degrade to 400, not a crash page.
      conn = Slink.OAuth.Plug.call(conn(:get, "/slack/oauth/callback?code=%C0"), plug_opts())
      assert conn.status == 400
      refute_receive {:installed, _}, 200
    end

    test "a failing exchange is a 502" do
      Application.put_env(:slink, :api_base_url, "http://127.0.0.1:1")

      log =
        capture_log(fn ->
          assert callback("code=abc", plug_opts()).status == 502
        end)

      assert log =~ "exchange failed"
      refute_receive {:installed, _}, 200
    end
  end
end
