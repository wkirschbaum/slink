defmodule Slink.OAuth.Plug do
  @moduledoc """
  The OAuth redirect endpoint: turns Slack's `?code=…` callback into a stored
  installation.

  Mount it at the app's Redirect URL, give it a 1-arity `:install` callback,
  and the code exchange is handled for you — your callback just persists the
  result:

      forward "/slack/oauth/callback", to: Slink.OAuth.Plug,
        init_opts: [
          client_id: "1234.5678",
          client_secret: fn -> System.fetch_env!("SLACK_CLIENT_SECRET") end,
          install: fn %Slink.OAuth.Install{} = install ->
            MyApp.Installs.put(install.team_id, install.bot_token)
          end
        ]

  Options:

    * `:client_id` (required) and `:client_secret` (required) — the app's
      client credentials (Basic Information page). The secret may be a 0-arity
      function, resolved per request (see the Phoenix compile-time pitfall in
      `Slink.EventsApi.Plug`).
    * `:install` (required) — called with the `Slink.OAuth.Install` after a
      successful exchange. Return `:ok` to finish the flow; `{:error, reason}`
      (or a raise) responds 500 without claiming success.
    * `:redirect_uri` — must match the authorize URL's, when one was used.
    * `:redirect_to` — where to send the installer's browser after success
      (302). Defaults to a minimal "app installed" page.
    * `:verify_state` — a 1-arity function receiving the redirect's `state`
      param (or `nil`); return `false` to reject the callback (403). Pair it
      with `authorize_url/1`'s `:state` to tie installs to a real session —
      without it, anyone can complete an install *they* initiated against your
      endpoint, which is usually harmless but worth closing on public apps.

  The installer clicking "Cancel" on the consent screen arrives here as
  `?error=access_denied`; that's answered with a friendly page, no callback.
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  @impl true
  def init(opts) do
    %{
      client_id: Keyword.fetch!(opts, :client_id),
      client_secret: Keyword.fetch!(opts, :client_secret),
      install: Keyword.fetch!(opts, :install),
      redirect_uri: Keyword.get(opts, :redirect_uri),
      redirect_to: Keyword.get(opts, :redirect_to),
      verify_state: Keyword.get(opts, :verify_state)
    }
  end

  @impl true
  def call(conn, opts) do
    params = query_params(conn)

    cond do
      is_binary(params["error"]) ->
        # e.g. access_denied — the installer cancelled on the consent screen.
        respond(conn, 200, "Installation cancelled.")

      not verified_state?(opts.verify_state, params["state"]) ->
        respond(conn, 403, "Invalid state parameter.")

      is_binary(params["code"]) ->
        exchange(conn, params["code"], opts)

      true ->
        respond(conn, 400, "Missing code parameter.")
    end
  end

  # A malformed query string (invalid percent-encoding) raises in
  # fetch_query_params — this is an unauthenticated, browser-facing endpoint,
  # so degrade to "no params" (→ 400) rather than a crash page.
  defp query_params(conn) do
    fetch_query_params(conn).query_params
  rescue
    _e -> %{}
  end

  defp verified_state?(nil, _state), do: true

  defp verified_state?(verify, state) when is_function(verify, 1),
    do: !!safe(fn -> verify.(state) end, false)

  # The exchange itself is contained too: a `:client_secret` function that
  # raises (e.g. a missing env var) must fail the request cleanly, not crash it.
  defp exchange(conn, code, opts) do
    exchange_opts = [
      client_id: opts.client_id,
      client_secret: opts.client_secret,
      redirect_uri: opts.redirect_uri
    ]

    case safe(fn -> Slink.OAuth.exchange(code, exchange_opts) end, :__crashed) do
      {:ok, install} ->
        complete(conn, install, opts)

      :__crashed ->
        respond(conn, 502, "Installation failed.")

      {:error, reason} ->
        # Slack's error string ("invalid_code", …) or a transport error —
        # neither carries secrets.
        Logger.warning("Slink.OAuth: code exchange failed: #{inspect(reason)}")
        respond(conn, 502, "Installation failed.")
    end
  end

  defp complete(conn, install, opts) do
    case safe(fn -> opts.install.(install) end, :__crashed) do
      :ok ->
        installed(conn, opts)

      :__crashed ->
        respond(conn, 500, "Installation failed.")

      other ->
        # Deliberately not inspected: an {:error, changeset}-style value from a
        # token store can embed the very tokens being saved.
        Logger.error(
          "Slink.OAuth: install callback returned #{describe(other)}; expected :ok — " <>
            "treating the installation as not saved"
        )

        respond(conn, 500, "Installation failed.")
    end
  end

  defp describe({:error, _reason}), do: "{:error, _}"
  defp describe(_other), do: "a non-:ok value"

  defp installed(conn, %{redirect_to: url}) when is_binary(url) do
    conn
    |> put_resp_header("location", url)
    |> respond(302, "Redirecting…")
  end

  defp installed(conn, _opts) do
    respond(conn, 200, "App installed. You can close this window.")
  end

  # Contain a user callback that raises or exits. Only the failure's *kind* is
  # logged — an exception from a token store can embed the tokens themselves
  # (the same lesson as the events plug's resolver_failed).
  defp safe(fun, on_crash) do
    fun.()
  rescue
    e ->
      Logger.error("Slink.OAuth: a callback raised #{inspect(e.__struct__)}")
      on_crash
  catch
    kind, _reason ->
      Logger.error("Slink.OAuth: a callback #{kind}ed")
      on_crash
  end

  defp respond(conn, status, text) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, text)
    |> halt()
  end
end
