defmodule Slink.API do
  @moduledoc """
  A thin Slack Web API client built on `Req`.

  Slack Web API methods are `POST`s to `https://slack.com/api/<method>` with a
  bearer token. Note that Slack returns HTTP 200 even on logical failures — the
  real status is in the `"ok"` field of the JSON body, which the helpers here
  surface as `{:error, reason}`.

  Tokens:

    * `apps.connections.open` needs an **app-level** token (`xapp-…`).
    * Everything else (e.g. `chat.postMessage`) needs a **bot** token (`xoxb-…`).
  """

  @default_base_url "https://slack.com/api"

  @doc """
  Open a Socket Mode WebSocket URL via `apps.connections.open`.

  Pass an app-level token (`xapp-…`) with the `connections:write` scope.
  """
  @spec open_connection(String.t()) :: {:ok, String.t()} | {:error, term()}
  def open_connection(app_token) do
    case call(app_token, "apps.connections.open", %{}) do
      {:ok, %{"url" => url}} -> {:ok, url}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Post a message with `chat.postMessage`.

  `opts` is merged into the request body (e.g. `%{thread_ts: ..., blocks: ...}`).
  """
  @spec post_message(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def post_message(bot_token, channel, text, opts \\ %{}) do
    call(bot_token, "chat.postMessage", Map.merge(%{channel: channel, text: text}, opts))
  end

  @doc """
  Add an emoji reaction (`name`, no colons) to the message at `channel`/`timestamp`
  via `reactions.add`. Needs the `reactions:write` scope.
  """
  @spec add_reaction(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def add_reaction(bot_token, channel, timestamp, name) do
    call(bot_token, "reactions.add", %{channel: channel, timestamp: timestamp, name: name})
  end

  @doc "Remove a reaction added with `add_reaction/4`, via `reactions.remove`."
  @spec remove_reaction(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def remove_reaction(bot_token, channel, timestamp, name) do
    call(bot_token, "reactions.remove", %{channel: channel, timestamp: timestamp, name: name})
  end

  @doc """
  Call any Web API method. Returns `{:ok, body}` when Slack replies `ok: true`,
  otherwise `{:error, reason}` (the Slack error string, or a transport error).
  """
  @spec call(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(token, method, params) do
    req = Req.new(base_url: base_url(), auth: {:bearer, token})

    case Req.post(req, url: "/" <> method, json: params) do
      {:ok, %Req.Response{body: %{"ok" => true} = body}} -> {:ok, body}
      {:ok, %Req.Response{body: %{"ok" => false, "error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Overridable base URL (`config :slink, api_base_url: ...`) — lets you point
  # at a mock Slack in tests. Defaults to the real Web API.
  defp base_url, do: Application.get_env(:slink, :api_base_url, @default_base_url)
end
