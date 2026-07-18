# Compiled only when the playground is enabled — see `Slink.Playground`.
if Application.compile_env(:slink, :playground, false) do
  defmodule Slink.Playground.Workspace do
    @moduledoc false
    # The fake workspace: one GenServer holding channels, messages, views,
    # response-url targets, files and the inspector log. Every mutation runs in
    # a handle_call and ends with a broadcast, so SSE subscribers always see a
    # consistent snapshot.

    use GenServer

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

    @doc "Fetch a view by id from the modal stack or the Home tab."
    def fetch_view(ws, view_id), do: GenServer.call(ws, {:fetch_view, view_id})

    @doc "The stored inbound envelope behind inspector entry `id` (for redelivery)."
    def envelope(ws, entry_id), do: GenServer.call(ws, {:envelope, entry_id})

    ## Mutations

    def set_base_url(ws, url), do: GenServer.call(ws, {:set_base_url, url})

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
      general = %{"id" => "C0GENERAL", "name" => "general", "is_im" => false}
      dm = %{"id" => "D0BOT", "name" => "slinkbot", "is_im" => true}

      {:ok,
       %{
         module: Keyword.fetch!(opts, :module),
         bot_token: Keyword.fetch!(opts, :bot_token),
         base_url: nil,
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

    def handle_call({:set_base_url, url}, _from, state) do
      {:reply, :ok, %{state | base_url: url}}
    end

    def handle_call({:api, method, params}, _from, state) do
      {reply, state, handled} = WebApi.call(state, method, params)

      entry = %{
        "dir" => "out",
        "label" => method,
        "request" => params,
        "response" => reply,
        "stubbed" => handled == :stubbed
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
      {ts, state} = WebApi.next_ts(state)

      msg =
        %{"type" => "message", "ts" => ts, "user" => state.user_id, "text" => text}
        |> put_present("thread_ts", thread_ts)

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
      {:reply, find_view(state, view_id), state}
    end

    def handle_call({:apply_ack, view_id, ack}, _from, state) do
      state =
        case ack["response_action"] || ack[:response_action] do
          "errors" ->
            # Validation failed: the modal stays; the browser renders the errors.
            state

          "clear" ->
            put_in(state.views["stack"], [])

          "update" ->
            replace_view(state, view_id, view_param(ack))

          "push" ->
            {view, state} = mint_pushed_view(state, view_param(ack))
            update_in(state.views["stack"], &(&1 ++ [view]))

          _close ->
            drop_view(state, view_id)
        end

      {:reply, :ok, broadcast(state)}
    end

    def handle_call({:pop_view, view_id}, _from, state) do
      case find_view(state, view_id) do
        {:ok, view} -> {:reply, {:ok, view}, state |> drop_view(view_id) |> broadcast()}
        :error -> {:reply, :error, state}
      end
    end

    def handle_call({:log_inbound, label, envelope, response}, _from, state) do
      entry =
        %{"dir" => "in", "label" => label, "request" => envelope}
        |> put_present("response", response)

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

    ## Internals

    defp snapshot_map(state) do
      %{
        "you" => state.user_id,
        "bot" => %{"user_id" => state.bot_user_id, "bot_id" => state.bot_id, "name" => "slinkbot"},
        "team_id" => state.team_id,
        "channels" => state.channels,
        "messages" => state.messages,
        "views" => state.views,
        "files" => state.files,
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

    defp find_view(state, view_id) do
      cond do
        state.views["home"] && state.views["home"]["id"] == view_id ->
          {:ok, state.views["home"]}

        view = Enum.find(state.views["stack"], &(&1["id"] == view_id)) ->
          {:ok, view}

        true ->
          :error
      end
    end

    defp drop_view(state, view_id) do
      update_in(state.views["stack"], fn stack ->
        Enum.reject(stack, &(&1["id"] == view_id))
      end)
    end

    defp replace_view(state, view_id, new_view) do
      update_in(state.views["stack"], fn stack ->
        Enum.map(stack, fn
          %{"id" => ^view_id} = old -> new_view |> stringify() |> Map.put("id", old["id"])
          other -> other
        end)
      end)
    end

    defp mint_pushed_view(state, view) do
      {n, state} = WebApi.next_seq(state)
      id = "V" <> String.pad_leading(Integer.to_string(n), 4, "0")
      {view |> stringify() |> Map.put("id", id), state}
    end

    defp view_param(ack), do: ack["view"] || ack[:view] || %{}

    # Ack payloads come from handler return values, so their views may be
    # atom-keyed (built with Slink.BlockKit); the workspace stores wire shapes.
    defp stringify(map), do: map |> JSON.encode!() |> JSON.decode!()

    defp put_present(map, _key, nil), do: map
    defp put_present(map, key, value), do: Map.put(map, key, value)
  end
end
