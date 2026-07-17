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

  defmodule Error do
    @moduledoc """
    Raised by `Slink.API.stream/3` when a page fetch fails mid-stream.

    A lazy `Stream` has no way to return `{:error, reason}`, so failures raise
    instead. `reason` is what `Slink.API.call/3` would have returned in the
    error tuple (Slack's error string, or a transport error).
    """
    defexception [:method, :reason]

    @impl true
    def message(%__MODULE__{method: method, reason: reason}) do
      "Slack Web API #{method} failed while streaming: #{inspect(reason)}"
    end
  end

  @doc """
  Open a Socket Mode WebSocket URL via `apps.connections.open`.

  Pass an app-level token (`xapp-…`) with the `connections:write` scope.
  """
  def open_connection(app_token) do
    case call(app_token, "apps.connections.open", %{}) do
      {:ok, %{"url" => url}} -> {:ok, url}
      {:ok, body} -> {:error, {:no_url, body}}
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

  @doc """
  Schedule a message for later with `chat.scheduleMessage`.

  `post_at` is a Unix timestamp (seconds). `opts` is merged into the body
  (e.g. `%{thread_ts: ...}`). Needs the `chat:write` scope.
  """
  def schedule_message(bot_token, channel, post_at, text, opts \\ %{}) do
    call(
      bot_token,
      "chat.scheduleMessage",
      Map.merge(%{channel: channel, post_at: post_at, text: text}, opts)
    )
  end

  @doc """
  Open (or resume) a direct message with `user` via `conversations.open`.

  Returns `{:ok, channel_id}` — the DM channel to post into (see
  `Slink.send_dm/4` for the one-call version). Needs the `im:write` scope.
  """
  def open_dm(bot_token, user) do
    case call(bot_token, "conversations.open", %{users: user}) do
      {:ok, %{"channel" => %{"id" => id}}} -> {:ok, id}
      {:ok, body} -> {:error, {:no_channel, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Join a public channel with `conversations.join`. Needs the `channels:join` scope."
  def join_channel(bot_token, channel) do
    call(bot_token, "conversations.join", %{channel: channel})
  end

  @doc """
  Fetch one page of a channel's message history with `conversations.history`.

  `opts` is merged into the body — most usefully `%{limit: ..., cursor: ...}`
  for paging (the next cursor is in `body["response_metadata"]["next_cursor"]`).
  Needs the relevant `*:history` scope for the conversation type.
  """
  def history(bot_token, channel, opts \\ %{}) do
    call(bot_token, "conversations.history", Map.merge(%{channel: channel}, opts))
  end

  @doc """
  Who this token authenticates as, via `auth.test`.

  The body's `"user_id"` is the bot's own user id (`Slink.Identity` caches this
  to power `context.bot_user_id` and `Slink.mentions_me?/1`).
  """
  def auth_test(token) do
    call(token, "auth.test", %{})
  end

  @doc "Look up a user's profile with `users.info`. Needs the `users:read` scope."
  def user_info(bot_token, user) do
    call(bot_token, "users.info", %{user: user})
  end

  @doc """
  Upload a file in one call, hiding Slack's three-step external upload flow
  (`files.getUploadURLExternal` → upload the bytes →
  `files.completeUploadExternal`).

  `content` is the file's binary content. Options (`:filename` required):

    * `:filename` — e.g. `"report.csv"`.
    * `:channel` — share the file into this channel; without it the file is
      uploaded private to the bot.
    * `:title` — display title (defaults to the filename on Slack's side).
    * `:initial_comment` — message text alongside the shared file.
    * `:thread_ts` — share into a thread.
    * `:alt_text` — image description for screen readers.
    * `:snippet_type` — syntax type for text snippets (e.g. `"elixir"`).

  Returns `{:ok, body}` from the completing call (`body["files"]` holds the
  file objects, ids included), or `{:error, reason}` from whichever step
  failed. Needs the `files:write` scope.
  """
  def upload_file(bot_token, content, opts) when is_binary(content) do
    opts = Map.new(opts)
    filename = Map.fetch!(opts, :filename)

    with {:ok, %{"upload_url" => url, "file_id" => file_id}} <-
           get_upload_url(bot_token, filename, byte_size(content), opts),
         :ok <- upload_bytes(url, content) do
      complete_upload(bot_token, file_id, opts)
    else
      {:ok, body} -> {:error, {:no_upload_url, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Sent form-encoded: every version of this method accepts that (JSON
  # acceptance is newer), so it works everywhere.
  defp get_upload_url(bot_token, filename, length, opts) do
    params =
      %{filename: filename, length: length}
      # The wire name really is `alt_txt` here (unlike Block Kit's alt_text).
      |> put_present(:alt_txt, opts[:alt_text])
      |> put_present(:snippet_type, opts[:snippet_type])

    form_call(bot_token, "files.getUploadURLExternal", params)
  end

  # The bytes go to a pre-signed URL — a plain POST, no bearer token.
  defp upload_bytes(url, content) do
    # Test seam: Slink.Testing swallows the byte upload here.
    case Application.get_env(:slink, :api_uploader) do
      nil ->
        case Req.post(Req.new(req_options()), url: url, body: content) do
          {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
          {:ok, %Req.Response{status: status, body: body}} -> {:error, {:upload, status, body}}
          {:error, reason} -> {:error, reason}
        end

      fun ->
        fun.(url, content)
    end
  end

  defp complete_upload(bot_token, file_id, opts) do
    file = put_present(%{id: file_id}, :title, opts[:title])

    params =
      %{files: [file]}
      |> put_present(:channel_id, opts[:channel])
      |> put_present(:initial_comment, opts[:initial_comment])
      |> put_present(:thread_ts, opts[:thread_ts])

    call(bot_token, "files.completeUploadExternal", params)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Like call/3 but form-encoded, for the few methods that don't accept JSON.
  defp form_call(token, method, params) do
    # Same test seam as call/3, so Slink.Testing captures these too.
    case Application.get_env(:slink, :api_caller) do
      nil ->
        req = Req.new([base_url: base_url(), auth: {:bearer, token}] ++ req_options())
        handle(Req.post(req, url: "/" <> method, form: params))

      fun ->
        fun.(token, method, params)
    end
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
  Lazily stream every page of a cursor-paginated Web API method.

  Emits each page's whole body, fetching the next page on demand by following
  `response_metadata.next_cursor` until Slack returns none. Extract the
  method's list field to stream items:

      Slink.API.stream(token, "conversations.history", %{channel: "C123"})
      |> Stream.flat_map(& &1["messages"])
      |> Enum.take(500)

  `params` gets `limit: 200` (Slack's recommended page size) unless you pass
  your own. Rate limiting is handled the same as `call/3` — a `429` waits out
  `Retry-After` and retries. A page fetch that still fails **raises**
  `Slink.API.Error` (a lazy stream can't return an error tuple), so wrap
  enumeration in a rescue if you need to handle it.
  """
  def stream(token, method, params \\ %{}) do
    params = params |> Map.new() |> put_default_limit()

    Stream.resource(
      fn -> {:page, params} end,
      fn
        :done ->
          {:halt, :done}

        {:page, page_params} ->
          case call(token, method, page_params) do
            {:ok, body} -> {[body], next_page(page_params, body)}
            {:error, reason} -> raise Error, method: method, reason: reason
          end
      end,
      fn _acc -> :ok end
    )
  end

  defp put_default_limit(params) do
    if Map.has_key?(params, :limit) or Map.has_key?(params, "limit") do
      params
    else
      Map.put(params, :limit, 200)
    end
  end

  defp next_page(params, %{"response_metadata" => %{"next_cursor" => cursor}})
       when is_binary(cursor) and cursor != "",
       do: {:page, Map.put(params, :cursor, cursor)}

  defp next_page(_params, _body), do: :done

  ## Assistant (AI app) methods — all need the `assistant:write` scope.

  @doc """
  Show a status line ("is thinking…") in an assistant thread, via
  `assistant.threads.setStatus`. Pass `""` to clear it.
  """
  def set_thread_status(bot_token, channel, thread_ts, status) do
    call(bot_token, "assistant.threads.setStatus", %{
      channel_id: channel,
      thread_ts: thread_ts,
      status: status
    })
  end

  @doc "Name an assistant thread, via `assistant.threads.setTitle`."
  def set_thread_title(bot_token, channel, thread_ts, title) do
    call(bot_token, "assistant.threads.setTitle", %{
      channel_id: channel,
      thread_ts: thread_ts,
      title: title
    })
  end

  @doc """
  Offer tappable prompts in an assistant thread, via
  `assistant.threads.setSuggestedPrompts`.

  `prompts` is a list of `%{title: ..., message: ...}` maps (the message is
  what gets sent when tapped). `opts` merges into the body (e.g. `%{title:
  "Try one of these"}` for the section header).
  """
  def set_suggested_prompts(bot_token, channel, thread_ts, prompts, opts \\ %{}) do
    call(
      bot_token,
      "assistant.threads.setSuggestedPrompts",
      Map.merge(%{channel_id: channel, thread_ts: thread_ts, prompts: prompts}, opts)
    )
  end

  @doc """
  Start a streaming message with `chat.startStream`.

  Streamed messages are always thread replies, so `thread_ts` is required.
  Returns the started message in the body — its `"ts"` is what
  `append_stream/4` and `stop_stream/4` take. When streaming into a *channel*
  (not the app's DM), Slack requires `recipient_user_id` and
  `recipient_team_id` in `opts`. See `Slink.stream_reply/3` for the high-level
  helper.
  """
  def start_stream(bot_token, channel, thread_ts, opts \\ %{}) do
    call(
      bot_token,
      "chat.startStream",
      Map.merge(%{channel: channel, thread_ts: thread_ts}, opts)
    )
  end

  @doc """
  Append markdown to a streaming message with `chat.appendStream`.

  `ts` is the streamed message's timestamp from `start_stream/4`.
  `markdown_text` is capped at 12,000 characters per call by Slack.
  """
  def append_stream(bot_token, channel, ts, markdown_text) do
    call(bot_token, "chat.appendStream", %{
      channel: channel,
      ts: ts,
      markdown_text: markdown_text
    })
  end

  @doc """
  Finish a streaming message with `chat.stopStream`.

  `opts` merges into the body — a final `markdown_text:` chunk, or `blocks:`
  (allowed only here, not on start/append).
  """
  def stop_stream(bot_token, channel, ts, opts \\ %{}) do
    call(bot_token, "chat.stopStream", Map.merge(%{channel: channel, ts: ts}, opts))
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
    # Test seam: Slink.Testing captures responder posts here.
    case Application.get_env(:slink, :api_responder) do
      nil ->
        case Req.post(Req.new(req_options()), url: response_url, json: params) do
          {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
          {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
          {:error, reason} -> {:error, reason}
        end

      fun ->
        fun.(response_url, params)
    end
  end

  @doc """
  Call any Web API method. Returns `{:ok, body}` when Slack replies `ok: true`,
  otherwise `{:error, reason}` (the Slack error string, or a transport error).
  """
  def call(token, method, params) do
    # Test seam: Slink.Testing captures Web API calls here.
    case Application.get_env(:slink, :api_caller) do
      nil ->
        req = Req.new([base_url: base_url(), auth: {:bearer, token}] ++ req_options())
        handle(Req.post(req, url: "/" <> method, json: params))

      fun ->
        fun.(token, method, params)
    end
  end

  @doc """
  Exchange an OAuth `code` for a workspace's tokens, via `oauth.v2.access`.

  This is the round-trip behind an "Add to Slack" install (see `Slink.OAuth`).
  Unlike other Web API methods it authenticates with the app's client
  credentials and a form-encoded body — no bearer token. `redirect_uri` must
  match the one used in the authorize URL, when one was used there.
  """
  def oauth_access(client_id, client_secret, code, redirect_uri \\ nil) do
    params = %{client_id: client_id, client_secret: client_secret, code: code}
    params = if redirect_uri, do: Map.put(params, :redirect_uri, redirect_uri), else: params

    req = Req.new([base_url: base_url()] ++ req_options())
    handle(Req.post(req, url: "/oauth.v2.access", form: params))
  end

  # Slack's uniform response convention: HTTP 200 with the real status in "ok".
  defp handle(result) do
    case result do
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
