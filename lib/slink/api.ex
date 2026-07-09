defmodule Slink.API do
  @moduledoc """
  A thin Slack Web API client built on `Req`.

  Slack Web API methods are `POST`s to `https://slack.com/api/<method>` with a
  bearer token. Note that Slack returns HTTP 200 even on logical failures — the
  real status is in the `"ok"` field of the JSON body, which the helpers here
  surface as `{:error, reason}`.

  Genuine rate limiting is different: Slack answers with HTTP `429` and a
  `Retry-After` header. `call/3` retries those automatically, honouring the
  header, so a burst backs off instead of dropping. Only `429` is retried —
  messages aren't idempotent, so we never re-POST on a transport error or a
  `5xx`.

  Tokens:

    * `apps.connections.open` needs an **app-level** token (`xapp-…`).
    * Everything else (e.g. `chat.postMessage`) needs a **bot** token (`xoxb-…`).
  """

  @default_base_url "https://slack.com/api"

  @doc """
  Open a Socket Mode WebSocket URL via `apps.connections.open`.

  Pass an app-level token (`xapp-…`) with the `connections:write` scope.
  """
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
  def post_message(bot_token, channel, text, opts \\ %{}) do
    call(bot_token, "chat.postMessage", Map.merge(%{channel: channel, text: text}, opts))
  end

  @doc """
  Update an existing message with `chat.update`.

  `timestamp` is the `ts` of the message to edit. `opts` is merged into the body
  (e.g. `%{blocks: ...}`). Needs the `chat:write` scope.
  """
  def update_message(bot_token, channel, timestamp, text, opts \\ %{}) do
    call(
      bot_token,
      "chat.update",
      Map.merge(%{channel: channel, ts: timestamp, text: text}, opts)
    )
  end

  @doc "Delete a message with `chat.delete`. Needs the `chat:write` scope."
  def delete_message(bot_token, channel, timestamp) do
    call(bot_token, "chat.delete", %{channel: channel, ts: timestamp})
  end

  @doc """
  Post a message only `user` can see, with `chat.postEphemeral`.

  Shows up for that one user in `channel` and vanishes on reload — good for
  private acknowledgements. `opts` is merged into the body. Needs `chat:write`.
  """
  def post_ephemeral(bot_token, channel, user, text, opts \\ %{}) do
    call(
      bot_token,
      "chat.postEphemeral",
      Map.merge(%{channel: channel, user: user, text: text}, opts)
    )
  end

  @doc """
  Get a permalink to the message at `channel`/`timestamp` via `chat.getPermalink`.

  Returns `{:ok, url}`.
  """
  def get_permalink(bot_token, channel, timestamp) do
    case call(bot_token, "chat.getPermalink", %{channel: channel, message_ts: timestamp}) do
      {:ok, %{"permalink" => url}} -> {:ok, url}
      {:ok, body} -> {:error, {:no_permalink, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Look up a user's profile with `users.info`. Needs the `users:read` scope."
  def user_info(bot_token, user) do
    call(bot_token, "users.info", %{user: user})
  end

  @doc """
  Add an emoji reaction (`name`, no colons) to the message at `channel`/`timestamp`
  via `reactions.add`. Needs the `reactions:write` scope.
  """
  def add_reaction(bot_token, channel, timestamp, name) do
    call(bot_token, "reactions.add", %{channel: channel, timestamp: timestamp, name: name})
  end

  @doc "Remove a reaction added with `add_reaction/4`, via `reactions.remove`."
  def remove_reaction(bot_token, channel, timestamp, name) do
    call(bot_token, "reactions.remove", %{channel: channel, timestamp: timestamp, name: name})
  end

  @doc """
  Open a modal with `views.open`.

  `trigger_id` comes from the interaction that opened it (see
  `Slink.Event.trigger_id/1`) and is only valid for ~3 seconds, so open the
  modal promptly. `view` is a Block Kit view payload (a map).
  """
  def open_view(bot_token, trigger_id, view) do
    call(bot_token, "views.open", %{trigger_id: trigger_id, view: view})
  end

  @doc """
  Replace the contents of an open modal with `views.update`.

  `view_id` is the id of the view returned when it was opened.
  """
  def update_view(bot_token, view_id, view) do
    call(bot_token, "views.update", %{view_id: view_id, view: view})
  end

  @doc "Push a new modal onto the stack of an open modal with `views.push`."
  def push_view(bot_token, trigger_id, view) do
    call(bot_token, "views.push", %{trigger_id: trigger_id, view: view})
  end

  @doc """
  Publish a Home tab view for `user` with `views.publish`.

  This is what populates a bot's **App Home** tab; call it from an
  `:app_home_opened` handler. Needs the App Home tab enabled for the app.
  """
  def publish_view(bot_token, user, view) do
    call(bot_token, "views.publish", %{user_id: user, view: view})
  end

  @doc """
  Reply to a slash command or interaction via its `response_url`.

  Slash commands and interactive payloads carry a short-lived `response_url`
  (valid ~30 minutes, up to 5 uses) — see `Slink.Event.response_url/1`. Unlike
  the Web API methods this is a plain POST to that URL with no bearer token.
  `params` is the message body, e.g. `%{response_type: "ephemeral", text: "…"}`
  (`"ephemeral"` — only the invoker sees it — or `"in_channel"`), optionally with
  `blocks`, `replace_original`, or `delete_original`.
  """
  def respond(response_url, params) do
    case Req.post(Req.new(req_options()), url: response_url, json: params) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Call any Web API method. Returns `{:ok, body}` when Slack replies `ok: true`,
  otherwise `{:error, reason}` (the Slack error string, or a transport error).
  """
  def call(token, method, params) do
    req = Req.new([base_url: base_url(), auth: {:bearer, token}] ++ req_options())

    case Req.post(req, url: "/" <> method, json: params) do
      {:ok, %Req.Response{body: %{"ok" => true} = body}} -> {:ok, body}
      {:ok, %Req.Response{body: %{"ok" => false, "error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Retry only genuine rate limiting (HTTP 429). Req reads the `Retry-After`
  # header to time the wait. We deliberately do not retry transport errors or
  # 5xx: a Slack POST isn't idempotent, so a blind retry risks a double-send.
  defp req_options, do: [retry: &retry/2, max_retries: 3]

  defp retry(_req, %Req.Response{status: 429}), do: true
  defp retry(_req, _response_or_exception), do: false

  # Overridable base URL (`config :slink, api_base_url: ...`) — lets you point
  # at a mock Slack in tests. Defaults to the real Web API.
  defp base_url, do: Application.get_env(:slink, :api_base_url, @default_base_url)
end
