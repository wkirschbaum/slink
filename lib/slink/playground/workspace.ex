# Compiled only when the playground is enabled — see `Slink.Playground`.
if Application.compile_env(:slink, :playground, false) do
  defmodule Slink.Playground.Workspace do
    @moduledoc false
    # The fake workspace: one GenServer holding channels, messages, views,
    # response-url targets, files and the inspector log. Every mutation runs in
    # a handle_call and ends with a broadcast, so SSE subscribers always see a
    # consistent snapshot. The state semantics live in WebApi; this process
    # only serializes access, logs, and fans out.

    use GenServer
    require Logger

    alias Slink.Playground.WebApi

    @inspector_cap 200

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    ## Reads

    def snapshot(ws), do: GenServer.call(ws, :snapshot)

    @doc "Static facts the router/event builder needs: module, token, ids, base_url."
    def info(ws), do: GenServer.call(ws, :info)

    @doc "Subscribe the caller to `{:playground, :state, json}` broadcasts. Returns the current snapshot JSON."
    def subscribe(ws), do: GenServer.call(ws, {:subscribe, self()})

    def fetch_message(ws, channel, ts), do: GenServer.call(ws, {:fetch_message, channel, ts})

    @doc "Fetch a view: `:home`, or an id from the modal stack or the Home tab."
    def fetch_view(ws, view_id), do: GenServer.call(ws, {:fetch_view, view_id})

    @doc "The stored inbound envelope behind inspector entry `id` (for redelivery)."
    def envelope(ws, entry_id), do: GenServer.call(ws, {:envelope, entry_id})

    ## Mutations

    @doc """
    Record the server's base URL once the listener knows its port.

    `api_env_before` is the `:api_base_url` value the playground is about to
    override — remembered so `terminate/2` can restore it when the playground
    stops. Callers that never take the env over (unit tests) omit it.
    """
    def set_base_url(ws, url, api_env_before \\ :unset) do
      GenServer.call(ws, {:set_base_url, url, api_env_before})
    end

    @doc "A Web API call from the bot. Returns the Slack-shaped reply map."
    def api_call(ws, method, params), do: GenServer.call(ws, {:api, method, params})

    @doc "A post to a minted response_url. Returns the reply map or :unknown_token."
    def respond(ws, token, params), do: GenServer.call(ws, {:respond, token, params})

    @doc "Bytes arrived at a minted upload URL."
    def record_upload(ws, file_id, size), do: GenServer.call(ws, {:upload, file_id, size})

    @doc "The human typed a message. Returns `{:ok, msg}` with its minted ts."
    def put_human_message(ws, channel, text, thread_ts) do
      GenServer.call(ws, {:human_message, channel, text, thread_ts})
    end

    @doc "The human clicked a reaction. `op` is \"add\" or \"remove\"."
    def user_reaction(ws, op, channel, ts, name) do
      GenServer.call(ws, {:user_reaction, op, channel, ts, name})
    end

    @doc "Mint a response_url targeting `message_ts` (nil for slash commands)."
    def mint_response_url(ws, channel, message_ts) do
      GenServer.call(ws, {:mint_response_url, channel, message_ts})
    end

    @doc "Apply a view_submission ack payload (response_action) to the modal stack."
    def apply_ack(ws, view_id, ack), do: GenServer.call(ws, {:apply_ack, view_id, ack})

    @doc "Close a modal from the UI. Returns `{:ok, view}` with the popped view."
    def pop_view(ws, view_id), do: GenServer.call(ws, {:pop_view, view_id})

    @doc "Log an inbound event dispatch. Returns the inspector entry id."
    def log_inbound(ws, label, envelope, response \\ nil) do
      GenServer.call(ws, {:log_inbound, label, envelope, response})
    end

    ## GenServer

    @impl true
    def init(opts) do
      # Trap exits so terminate/2 runs on supervisor shutdown and can restore
      # the :api_base_url this playground took over.
      Process.flag(:trap_exit, true)

      general = %{"id" => "C0GENERAL", "name" => "general", "is_im" => false}
      dm = %{"id" => "D0BOT", "name" => "slinkbot", "is_im" => true}

      {:ok,
       %{
         module: Keyword.fetch!(opts, :module),
         bot_token: Keyword.fetch!(opts, :bot_token),
         base_url: nil,
         api_env_before: :unset,
         bot_user_id: "U0BOT",
         bot_id: "B0BOT",
         user_id: "U0DEV",
         team_id: "T0PLAY",
         channels: [general, dm],
         messages: %{general["id"] => [], dm["id"] => []},
         seq: 0,
         views: %{"stack" => [], "home" => nil},
         response_urls: %{},
         files: %{},
         inspector: [],
         subscribers: %{}
       }}
    end

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, snapshot_map(state), state}

    def handle_call(:info, _from, state) do
      {:reply,
       Map.take(state, [
         :module,
         :bot_token,
         :base_url,
         :bot_user_id,
         :bot_id,
         :user_id,
         :team_id,
         :channels
       ]), state}
    end

    def handle_call({:subscribe, pid}, _from, state) do
      ref = Process.monitor(pid)
      state = put_in(state.subscribers[pid], ref)
      {:reply, JSON.encode!(snapshot_map(state)), state}
    end

    def handle_call({:set_base_url, url, api_env_before}, _from, state) do
      {:reply, :ok, %{state | base_url: url, api_env_before: api_env_before}}
    end

    def handle_call({:api, method, params}, _from, state) do
      # A malformed request must answer like Slack would, never take the
      # workspace (and all its state) down with it.
      {reply, state, stubbed?} =
        try do
          {reply, state, handled} = WebApi.call(state, method, params)
          {reply, state, handled == :stubbed}
        rescue
          e ->
            Logger.error(
              "Slink.Playground: #{method} crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
            )

            {%{"ok" => false, "error" => "fatal_error"}, state, false}
        end

      entry = %{
        "dir" => "out",
        "label" => method,
        "request" => params,
        "response" => reply,
        "stubbed" => stubbed?
      }

      {:reply, reply, state |> log(entry) |> broadcast()}
    end

    def handle_call({:respond, token, params}, _from, state) do
      case WebApi.respond(state, token, params) do
        :unknown_token ->
          {:reply, :unknown_token, state}

        {reply, state} ->
          entry = %{
            "dir" => "out",
            "label" => "response_url",
            "request" => params,
            "response" => reply
          }

          {:reply, reply, state |> log(entry) |> broadcast()}
      end
    end

    def handle_call({:upload, file_id, size}, _from, state) do
      case state.files[file_id] do
        nil ->
          {:reply, :error, state}

        _file ->
          state = put_in(state.files[file_id]["size"], size)

          entry = %{
            "dir" => "out",
            "label" => "upload " <> file_id,
            "request" => %{"bytes" => size},
            "response" => %{"ok" => true}
          }

          {:reply, :ok, state |> log(entry) |> broadcast()}
      end
    end

    def handle_call({:human_message, channel, text, thread_ts}, _from, state) do
      {msg, state} = WebApi.human_message(state, text, thread_ts)
      state = WebApi.put_message(state, channel, msg)
      {:reply, {:ok, msg}, broadcast(state)}
    end

    def handle_call({:user_reaction, op, channel, ts, name}, _from, state) do
      case WebApi.react(state, channel, ts, name, state.user_id, op) do
        {:ok, state} -> {:reply, :ok, broadcast(state)}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end

    def handle_call({:mint_response_url, channel, message_ts}, _from, state) do
      token = "ru#{System.unique_integer([:positive])}"

      state =
        put_in(state.response_urls[token], %{"channel" => channel, "message_ts" => message_ts})

      {:reply, "#{state.base_url}/respond/#{token}", state}
    end

    def handle_call({:fetch_message, channel, ts}, _from, state) do
      {:reply, WebApi.fetch_message(state, channel, ts), state}
    end

    def handle_call({:fetch_view, view_id}, _from, state) do
      {:reply, WebApi.find_view(state, view_id), state}
    end

    def handle_call({:apply_ack, view_id, ack}, _from, state) do
      # Acks come from handler return values, so they may be atom-keyed (built
      # with Slink.BlockKit); normalise once at this boundary — WebApi (and
      # the stored stack) deal in wire shapes only.
      state = WebApi.apply_ack(state, view_id, stringify(ack))
      {:reply, :ok, broadcast(state)}
    end

    def handle_call({:pop_view, view_id}, _from, state) do
      case WebApi.find_view(state, view_id) do
        {:ok, view} ->
          {:reply, {:ok, view}, state |> WebApi.drop_view(view["id"]) |> broadcast()}

        :error ->
          {:reply, :error, state}
      end
    end

    def handle_call({:log_inbound, label, envelope, response}, _from, state) do
      entry =
        %{"dir" => "in", "label" => label, "request" => envelope}
        |> WebApi.put_present("response", response)

      state = log(state, entry)
      [%{"id" => id} | _] = state.inspector
      {:reply, id, broadcast(state)}
    end

    def handle_call({:envelope, entry_id}, _from, state) do
      case Enum.find(state.inspector, &(&1["id"] == entry_id and &1["dir"] == "in")) do
        nil -> {:reply, :error, state}
        entry -> {:reply, {:ok, entry["request"]}, state}
      end
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
      {_ref, state} = pop_in(state.subscribers[pid])
      {:noreply, state}
    end

    def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

    # Give :api_base_url back on shutdown, so a VM that outlives the
    # playground (a test suite, an iex session) isn't left pointing at a dead
    # port. Only undone if the env still holds this playground's URL.
    @impl true
    def terminate(_reason, %{api_env_before: before, base_url: base}) when is_binary(base) do
      if before != :unset and Application.get_env(:slink, :api_base_url) == base <> "/api" do
        case before do
          nil -> Application.delete_env(:slink, :api_base_url)
          url -> Application.put_env(:slink, :api_base_url, url)
        end
      end

      :ok
    end

    def terminate(_reason, _state), do: :ok

    ## Internals

    defp snapshot_map(state) do
      %{
        "you" => state.user_id,
        "bot" => %{"user_id" => state.bot_user_id, "bot_id" => state.bot_id, "name" => "slinkbot"},
        "channels" => state.channels,
        "messages" => state.messages,
        "views" => state.views,
        "inspector" => state.inspector
      }
    end

    defp broadcast(state) do
      json = JSON.encode!(snapshot_map(state))

      for {pid, _ref} <- state.subscribers do
        send(pid, {:playground, :state, json})
      end

      state
    end

    defp log(state, entry) do
      {n, state} = WebApi.next_seq(state)
      entry = Map.put(entry, "id", n)
      %{state | inspector: Enum.take([entry | state.inspector], @inspector_cap)}
    end

    defp stringify(map), do: map |> JSON.encode!() |> JSON.decode!()
  end
end
