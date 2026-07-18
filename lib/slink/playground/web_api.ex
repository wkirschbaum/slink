# Compiled only when the playground is enabled — see `Slink.Playground`.
if Application.compile_env(:slink, :playground, false) do
  defmodule Slink.Playground.WebApi do
    @moduledoc false
    # The fake Slack Web API: pure state transitions over the workspace state,
    # one clause per method. Requests arrive string-keyed (decoded JSON or form
    # bodies — exactly what the real API receives); replies follow Slack's
    # convention of HTTP 200 with the real status in "ok".

    @doc """
    Handle a Web API `method`. Returns `{reply, state, :handled | :stubbed}` —
    a stubbed method answered a generic `ok: true` without touching state, so
    the inspector can mark it as not really simulated.
    """
    def call(state, method, params) do
      case handle(state, method, params) do
        :stub -> {%{"ok" => true}, state, :stubbed}
        {reply, state} -> {reply, state, :handled}
      end
    end

    defp handle(state, "auth.test", _params) do
      {%{
         "ok" => true,
         "url" => state.base_url,
         "team" => "Playground",
         "team_id" => state.team_id,
         "user" => "slinkbot",
         "user_id" => state.bot_user_id,
         "bot_id" => state.bot_id
       }, state}
    end

    defp handle(state, "chat.postMessage", %{"channel" => channel} = params) do
      if channel?(state, channel) do
        {msg, state} = bot_message(state, params)
        state = put_message(state, channel, msg)
        {%{"ok" => true, "channel" => channel, "ts" => msg["ts"], "message" => msg}, state}
      else
        {error("channel_not_found"), state}
      end
    end

    defp handle(state, "chat.postEphemeral", %{"channel" => channel} = params) do
      cond do
        not channel?(state, channel) ->
          {error("channel_not_found"), state}

        params["user"] not in [state.user_id, state.bot_user_id] ->
          {error("user_not_found"), state}

        true ->
          {msg, state} = bot_message(state, params)
          msg = Map.put(msg, "ephemeral", true)
          state = put_message(state, channel, msg)
          {%{"ok" => true, "message_ts" => msg["ts"]}, state}
      end
    end

    defp handle(state, "chat.update", %{"channel" => channel, "ts" => ts} = params) do
      update_message(state, channel, ts, fn msg ->
        msg
        |> put_present("text", params["text"])
        |> put_present("blocks", params["blocks"])
        |> put_present("attachments", params["attachments"])
        |> Map.put("edited", %{"user" => state.bot_user_id, "ts" => ts})
      end)
      |> case do
        {:ok, state} ->
          {%{"ok" => true, "channel" => channel, "ts" => ts, "text" => params["text"]}, state}

        :error ->
          {error(not_found_error(state, channel)), state}
      end
    end

    defp handle(state, "chat.delete", %{"channel" => channel, "ts" => ts}) do
      case pop_message(state, channel, ts) do
        {:ok, _msg, state} ->
          # Deleting a thread root takes its replies with it, like Slack does.
          state =
            update_channel(state, channel, fn msgs ->
              Enum.reject(msgs, &(&1["thread_ts"] == ts))
            end)

          {%{"ok" => true, "channel" => channel, "ts" => ts}, state}

        :error ->
          {error(not_found_error(state, channel)), state}
      end
    end

    defp handle(state, "reactions." <> op, %{"channel" => channel, "name" => name} = params)
         when op in ["add", "remove"] do
      ts = params["timestamp"]

      case react(state, channel, ts, name, state.bot_user_id, op) do
        {:ok, state} -> {%{"ok" => true}, state}
        {:error, reason} -> {error(reason), state}
      end
    end

    defp handle(state, "conversations.open", _params) do
      {%{"ok" => true, "channel" => %{"id" => dm_id(state)}}, state}
    end

    defp handle(state, "conversations.info", %{"channel" => channel}) do
      case Enum.find(state.channels, &(&1["id"] == channel)) do
        nil -> {error("channel_not_found"), state}
        map -> {%{"ok" => true, "channel" => map}, state}
      end
    end

    defp handle(state, "conversations.join", %{"channel" => channel}) do
      case Enum.find(state.channels, &(&1["id"] == channel)) do
        nil -> {error("channel_not_found"), state}
        map -> {%{"ok" => true, "channel" => map}, state}
      end
    end

    defp handle(state, "conversations.history", %{"channel" => channel}) do
      if channel?(state, channel) do
        messages =
          state.messages[channel]
          |> Enum.filter(&top_level?/1)
          |> Enum.reverse()

        {page(messages), state}
      else
        {error("channel_not_found"), state}
      end
    end

    defp handle(state, "conversations.replies", %{"channel" => channel, "ts" => ts}) do
      messages =
        Enum.filter(state.messages[channel] || [], fn msg ->
          msg["ts"] == ts or msg["thread_ts"] == ts
        end)

      case messages do
        [] -> {error("thread_not_found"), state}
        messages -> {page(messages), state}
      end
    end

    defp handle(state, "views.open", %{"view" => view}) when is_map(view) do
      {view, state} = mint_view(state, view)
      state = update_in(state.views["stack"], &(&1 ++ [view]))
      {%{"ok" => true, "view" => view}, state}
    end

    defp handle(state, "views.push", %{"view" => view}) when is_map(view) do
      {view, state} = mint_view(state, view)
      state = update_in(state.views["stack"], &(&1 ++ [view]))
      {%{"ok" => true, "view" => view}, state}
    end

    defp handle(state, "views.update", %{"view" => view} = params) when is_map(view) do
      id = params["view_id"]

      case Enum.split_while(state.views["stack"], &(&1["id"] != id)) do
        {_before, []} ->
          {error("not_found"), state}

        {before, [old | rest]} ->
          view = view |> Map.put("id", old["id"]) |> Map.put_new("state", empty_view_state())
          state = put_in(state.views["stack"], before ++ [view | rest])
          {%{"ok" => true, "view" => view}, state}
      end
    end

    defp handle(state, "views.publish", %{"view" => view}) when is_map(view) do
      view = Map.put(view, "id", "VHOME")
      state = put_in(state.views["home"], view)
      {%{"ok" => true, "view" => view}, state}
    end

    defp handle(state, "chat.startStream", %{"channel" => channel} = params) do
      cond do
        not channel?(state, channel) ->
          {error("channel_not_found"), state}

        not is_binary(params["thread_ts"]) ->
          # Slack only streams into threads; slink always passes thread_ts.
          {error("invalid_arguments"), state}

        true ->
          {msg, state} = bot_message(state, Map.put(params, "text", ""))
          msg = Map.put(msg, "streaming", true)
          state = put_message(state, channel, msg)
          {%{"ok" => true, "channel" => channel, "ts" => msg["ts"]}, state}
      end
    end

    defp handle(state, "chat.appendStream", %{"channel" => channel, "ts" => ts} = params) do
      update_message(state, channel, ts, fn msg ->
        Map.update(msg, "text", "", &(&1 <> (params["markdown_text"] || "")))
      end)
      |> case do
        {:ok, state} -> {%{"ok" => true, "channel" => channel, "ts" => ts}, state}
        :error -> {error(not_found_error(state, channel)), state}
      end
    end

    defp handle(state, "chat.stopStream", %{"channel" => channel, "ts" => ts} = params) do
      update_message(state, channel, ts, fn msg ->
        msg
        |> Map.update("text", "", &(&1 <> (params["markdown_text"] || "")))
        |> put_present("blocks", params["blocks"])
        |> Map.delete("streaming")
      end)
      |> case do
        {:ok, state} -> {%{"ok" => true, "channel" => channel, "ts" => ts}, state}
        :error -> {error(not_found_error(state, channel)), state}
      end
    end

    defp handle(state, "chat.getPermalink", %{"channel" => channel, "message_ts" => ts}) do
      case fetch_message(state, channel, ts) do
        {:ok, _msg} ->
          link = "#{state.base_url}/archives/#{channel}/p#{String.replace(ts, ".", "")}"
          {%{"ok" => true, "channel" => channel, "permalink" => link}, state}

        :error ->
          {error("message_not_found"), state}
      end
    end

    defp handle(state, "files.getUploadURLExternal", %{"filename" => filename} = params) do
      {n, state} = next_seq(state)
      id = "F" <> String.pad_leading(Integer.to_string(n), 4, "0")

      file = %{
        "id" => id,
        "name" => filename,
        "title" => filename,
        "size" => int(params["length"]),
        "pending" => true
      }

      state = put_in(state.files[id], file)

      {%{"ok" => true, "file_id" => id, "upload_url" => "#{state.base_url}/api/upload/#{id}"},
       state}
    end

    defp handle(state, "files.completeUploadExternal", %{"files" => files} = params)
         when is_list(files) do
      {completed, state} =
        Enum.map_reduce(files, state, fn %{"id" => id} = spec, state ->
          state =
            update_in(state.files[id], fn file ->
              (file || %{"id" => id})
              |> Map.delete("pending")
              |> put_present("title", spec["title"])
            end)

          {state.files[id], state}
        end)

      state =
        case params["channel_id"] do
          channel when is_binary(channel) ->
            {msg, state} =
              bot_message(state, %{
                "text" => params["initial_comment"] || "",
                "thread_ts" => params["thread_ts"]
              })

            put_message(state, channel, Map.put(msg, "files", completed))

          _no_share ->
            state
        end

      {%{"ok" => true, "files" => completed}, state}
    end

    defp handle(_state, _method, _params), do: :stub

    @doc """
    Handle a post to a minted `response_url` (see `Slink.API.respond/2`).

    Implements Slack's semantics: `replace_original` / `delete_original` act on
    the message the URL was minted against; otherwise a new message is posted —
    ephemeral by default, in-channel with `response_type: "in_channel"`.
    Returns `{reply, state}` or `:unknown_token`.
    """
    def respond(state, token, params) do
      case state.response_urls[token] do
        nil -> :unknown_token
        target -> {%{"ok" => true}, do_respond(state, target, params)}
      end
    end

    defp do_respond(state, %{"channel" => channel, "message_ts" => ts}, params) do
      cond do
        params["delete_original"] in [true, "true"] and is_binary(ts) ->
          case pop_message(state, channel, ts) do
            {:ok, _msg, state} -> state
            :error -> state
          end

        params["replace_original"] in [true, "true"] and is_binary(ts) ->
          case update_message(state, channel, ts, fn msg ->
                 msg
                 |> put_present("text", params["text"])
                 |> put_present("blocks", params["blocks"])
                 |> put_present("attachments", params["attachments"])
               end) do
            {:ok, state} -> state
            :error -> state
          end

        true ->
          {msg, state} = bot_message(state, params)

          msg =
            if params["response_type"] == "in_channel" do
              msg
            else
              Map.put(msg, "ephemeral", true)
            end

          # A response to a threaded message lands in that thread, like Slack.
          msg =
            with true <- is_binary(ts),
                 {:ok, original} <- fetch_message(state, channel, ts),
                 root when is_binary(root) <- original["thread_ts"] do
              Map.put(msg, "thread_ts", root)
            else
              _ -> msg
            end

          put_message(state, channel, msg)
      end
    end

    ## Shared state helpers (used by Workspace for UI-initiated changes too)

    @doc "Mint the next seq number."
    def next_seq(state), do: {state.seq + 1, %{state | seq: state.seq + 1}}

    @doc "Mint a monotonic, Slack-shaped message timestamp."
    def next_ts(state) do
      {n, state} = next_seq(state)

      {"#{1_700_000_000 + div(n, 1_000_000)}." <>
         String.pad_leading(Integer.to_string(rem(n, 1_000_000)), 6, "0"), state}
    end

    @doc "Append a message to a channel, bumping its thread root's reply_count."
    def put_message(state, channel, msg) do
      state = update_channel(state, channel, &(&1 ++ [msg]))
      root = msg["thread_ts"]

      if is_binary(root) and root != msg["ts"] do
        case update_message(state, channel, root, fn m ->
               Map.update(m, "reply_count", 1, &(&1 + 1))
             end) do
          {:ok, state} -> state
          :error -> state
        end
      else
        state
      end
    end

    @doc "Fetch the message at channel/ts."
    def fetch_message(state, channel, ts) do
      case Enum.find(state.messages[channel] || [], &(&1["ts"] == ts)) do
        nil -> :error
        msg -> {:ok, msg}
      end
    end

    @doc "Replace the message at channel/ts via `fun`."
    def update_message(state, channel, ts, fun) do
      msgs = state.messages[channel] || []

      case Enum.split_while(msgs, &(&1["ts"] != ts)) do
        {_before, []} ->
          :error

        {before, [msg | rest]} ->
          {:ok, put_in(state.messages[channel], before ++ [fun.(msg) | rest])}
      end
    end

    @doc "Remove and return the message at channel/ts."
    def pop_message(state, channel, ts) do
      case fetch_message(state, channel, ts) do
        {:ok, msg} ->
          {:ok, msg, update_channel(state, channel, &Enum.reject(&1, fn m -> m["ts"] == ts end))}

        :error ->
          :error
      end
    end

    @doc "Add or remove `user`'s reaction on channel/ts. `op` is \"add\" or \"remove\"."
    def react(state, channel, ts, name, user, op) do
      with {:ok, msg} <- fetch_message(state, channel, ts) do
        reactions = msg["reactions"] || []
        existing = Enum.find(reactions, &(&1["name"] == name))
        reacted? = existing && user in existing["users"]

        cond do
          op == "add" and reacted? ->
            {:error, "already_reacted"}

          op == "remove" and !reacted? ->
            {:error, "no_reaction"}

          op == "add" ->
            reactions =
              if existing do
                Enum.map(reactions, fn
                  %{"name" => ^name} = r ->
                    %{r | "users" => r["users"] ++ [user], "count" => r["count"] + 1}

                  r ->
                    r
                end)
              else
                reactions ++ [%{"name" => name, "users" => [user], "count" => 1}]
              end

            put_reactions(state, channel, ts, reactions)

          op == "remove" ->
            reactions =
              reactions
              |> Enum.map(fn
                %{"name" => ^name} = r ->
                  %{r | "users" => r["users"] -- [user], "count" => r["count"] - 1}

                r ->
                  r
              end)
              |> Enum.reject(&(&1["count"] == 0))

            put_reactions(state, channel, ts, reactions)
        end
      else
        :error -> {:error, "message_not_found"}
      end
    end

    defp update_channel(state, channel, fun) do
      update_in(state.messages[channel], fn msgs -> fun.(msgs || []) end)
    end

    defp put_reactions(state, channel, ts, reactions) do
      update_message(state, channel, ts, fn msg ->
        if reactions == [] do
          Map.delete(msg, "reactions")
        else
          Map.put(msg, "reactions", reactions)
        end
      end)
    end

    ## Private helpers

    defp bot_message(state, params) do
      {ts, state} = next_ts(state)

      msg =
        %{
          "type" => "message",
          "ts" => ts,
          "user" => state.bot_user_id,
          "bot_id" => state.bot_id,
          "text" => params["text"] || ""
        }
        |> put_present("blocks", params["blocks"])
        |> put_present("attachments", params["attachments"])
        |> put_present("thread_ts", params["thread_ts"])

      {msg, state}
    end

    defp mint_view(state, view) do
      {n, state} = next_seq(state)

      view =
        view
        |> Map.put("id", "V" <> String.pad_leading(Integer.to_string(n), 4, "0"))
        |> Map.put_new("state", empty_view_state())

      {view, state}
    end

    defp empty_view_state, do: %{"values" => %{}}

    defp page(messages) do
      %{
        "ok" => true,
        "messages" => messages,
        "has_more" => false,
        "response_metadata" => %{"next_cursor" => ""}
      }
    end

    defp top_level?(msg), do: msg["thread_ts"] in [nil, msg["ts"]]

    defp channel?(state, id), do: Enum.any?(state.channels, &(&1["id"] == id))

    defp dm_id(state) do
      Enum.find_value(state.channels, fn c -> c["is_im"] && c["id"] end)
    end

    # chat.update / chat.delete / reactions report the more specific error first,
    # like Slack: an unknown channel is channel_not_found, else message_not_found.
    defp not_found_error(state, channel) do
      if channel?(state, channel), do: "message_not_found", else: "channel_not_found"
    end

    defp error(reason), do: %{"ok" => false, "error" => reason}

    defp int(value) when is_integer(value), do: value
    defp int(value) when is_binary(value), do: String.to_integer(value)
    defp int(_), do: 0

    defp put_present(map, _key, nil), do: map
    defp put_present(map, key, value), do: Map.put(map, key, value)
  end
end
