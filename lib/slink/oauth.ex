defmodule Slink.OAuth do
  @moduledoc """
  The OAuth install flow for a multi-workspace ("Add to Slack") app.

  Installing an app into a workspace is a standard OAuth v2 dance:

  1. Send the installer to Slack's consent screen — `authorize_url/1`.
  2. Slack redirects back to your app with a short-lived `code`.
  3. Exchange the code for that workspace's bot token — `exchange/2` (or let
     `Slink.OAuth.Plug` handle steps 2–3 as a mounted endpoint).
  4. Persist `{team_id, bot_token}` in your own store, and hand it back per
     request via the transports' `:bot_token` resolver (see *Multiple
     workspaces* in `Slink.EventsApi.Plug`).

  Slink does the Slack round-trips; the persistence is deliberately yours.

  ## Example

      # In a controller / LiveView: the "Add to Slack" link.
      Slink.OAuth.authorize_url(
        client_id: client_id,
        scopes: ~w(app_mentions:read chat:write commands),
        redirect_uri: "https://example.com/slack/oauth/callback",
        state: my_csrf_token
      )

      # In the callback route (or mount Slink.OAuth.Plug instead):
      {:ok, install} = Slink.OAuth.exchange(code,
        client_id: client_id,
        client_secret: client_secret,
        redirect_uri: "https://example.com/slack/oauth/callback"
      )

      MyApp.Installs.put(install.team_id, install.bot_token)
  """

  defmodule Install do
    @moduledoc """
    A completed workspace installation, normalised from `oauth.v2.access`.

    `raw` is Slack's full response for anything not surfaced (incoming
    webhooks, the user token, granted scopes, …).
    """

    # The bot token is a secret — keep it out of inspects and crash reports,
    # like Slink.Context does.
    @derive {Inspect, except: [:bot_token, :raw]}
    defstruct [
      :team_id,
      :team_name,
      :enterprise_id,
      :bot_token,
      :bot_user_id,
      :app_id,
      :authed_user_id,
      :raw
    ]

    @type t :: %__MODULE__{
            team_id: String.t() | nil,
            team_name: String.t() | nil,
            enterprise_id: String.t() | nil,
            bot_token: String.t() | nil,
            bot_user_id: String.t() | nil,
            app_id: String.t() | nil,
            authed_user_id: String.t() | nil,
            raw: map()
          }
  end

  @authorize_url "https://slack.com/oauth/v2/authorize"

  @doc """
  The Slack consent-screen URL an installer should be sent to.

  Options:

    * `:client_id` (required) — the app's Client ID (Basic Information page).
    * `:scopes` (required) — bot scopes to request: a list or comma-string.
    * `:redirect_uri` — where Slack sends the installer back to (must be one of
      the app's configured Redirect URLs; optional when exactly one is
      configured there).
    * `:state` — an opaque value echoed back on the redirect. Use a value tied
      to the installer's session and check it in the callback (see
      `Slink.OAuth.Plug`'s `:verify_state`) to prevent forged installs.
    * `:user_scopes` — user-token scopes, if the app requests any.
    * `:team` — a workspace id to pre-select on the consent screen.
  """
  def authorize_url(opts) do
    query =
      [
        client_id: Keyword.fetch!(opts, :client_id),
        scope: scopes(Keyword.fetch!(opts, :scopes)),
        redirect_uri: opts[:redirect_uri],
        state: opts[:state],
        user_scope: opts[:user_scopes] && scopes(opts[:user_scopes]),
        team: opts[:team]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> URI.encode_query()

    @authorize_url <> "?" <> query
  end

  defp scopes([]), do: nil
  defp scopes(scopes) when is_list(scopes), do: Enum.join(scopes, ",")
  defp scopes(scopes) when is_binary(scopes), do: scopes

  @doc """
  Exchange the redirect's `code` for the workspace's tokens.

  Calls `oauth.v2.access` with the app's client credentials and returns
  `{:ok, %Slink.OAuth.Install{}}`, or `{:error, reason}` — Slack's error string
  (e.g. `"invalid_code"` for an expired/reused code) or a transport error.

  Options: `:client_id` and `:client_secret` (required; the secret may be a
  0-arity function, resolved here), and `:redirect_uri` (required if the
  authorize URL carried one).
  """
  def exchange(code, opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    client_secret = resolve(Keyword.fetch!(opts, :client_secret))

    case Slink.API.oauth_access(client_id, client_secret, code, opts[:redirect_uri]) do
      {:ok, body} -> {:ok, install(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve(fun) when is_function(fun, 0), do: fun.()
  defp resolve(value), do: value

  # Normalise the oauth.v2.access body. Lookups are nil-safe (Slack sends
  # `"enterprise": null` outside Enterprise Grid).
  defp install(body) do
    %Install{
      team_id: get_in(body, ["team", "id"]),
      team_name: get_in(body, ["team", "name"]),
      enterprise_id: get_in(body, ["enterprise", "id"]),
      bot_token: body["access_token"],
      bot_user_id: body["bot_user_id"],
      app_id: body["app_id"],
      authed_user_id: get_in(body, ["authed_user", "id"]),
      raw: body
    }
  end
end
