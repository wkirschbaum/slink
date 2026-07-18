# Compiled only when the playground is enabled — see `Slink.Playground`.
if Application.compile_env(:slink, :playground, false) do
  defmodule Slink.Playground.Events do
    @moduledoc false
    # Turns UI actions into Socket-Mode envelopes and dispatches them to the
    # bot exactly as the Socket Mode transport would: through
    # Slink.Event.from_socket_mode/1 and Slink.Dispatcher — async for
    # everything except view_submission, which round-trips its ack.

    alias Slink.{Context, Dispatcher, Event}
    alias Slink.Playground.Workspace

    @doc """
    The human sent `text`. Stores the message, dispatches a `message` event,
    and — when the bot is mentioned in a channel — a separate `app_mention`
    with its own event_id, mirroring Slack's double delivery.
    """
    def user_message(ws, channel, text, thread_ts) do
      info = Workspace.info(ws)
      {:ok, msg} = Workspace.put_human_message(ws, channel, text, thread_ts)

      inner =
        %{
          "type" => "message",
          "user" => info.user_id,
          "channel" => channel,
          "channel_type" => channel_type(info, channel),
          "ts" => msg["ts"],
          "text" => text
        }
        |> put_present("thread_ts", thread_ts)

      dispatch(ws, info, event_callback(info, inner))

      if String.contains?(text, "<@#{info.bot_user_id}>") and
           channel_type(info, channel) == "channel" do
        mention = Map.put(inner, "type", "app_mention")
        dispatch(ws, info, event_callback(info, mention))
      end

      :ok
    end

    @doc "The human ran a slash command."
    def slash_command(ws, channel, command, text) do
      info = Workspace.info(ws)

      payload = %{
        "command" => command,
        "text" => text,
        "channel_id" => channel,
        "channel_name" => channel_name(info, channel),
        "user_id" => info.user_id,
        "team_id" => info.team_id,
        "response_url" => Workspace.mint_response_url(ws, channel, nil),
        "trigger_id" => trigger_id()
      }

      dispatch(ws, info, envelope("slash_commands", payload))
    end

    @doc """
    The human clicked an interactive element on a message. `action` is the
    element's payload from the UI, e.g. `%{"type" => "button", "action_id" =>
    ..., "value" => ...}` or a static_select with `"selected_option"`.
    """
    def message_action(ws, channel, message_ts, action) do
      info = Workspace.info(ws)

      with {:ok, msg} <- Workspace.fetch_message(ws, channel, message_ts) do
        payload = %{
          "type" => "block_actions",
          "user" => %{"id" => info.user_id, "username" => "you"},
          "team" => %{"id" => info.team_id},
          "channel" => %{"id" => channel, "name" => channel_name(info, channel)},
          "container" => %{
            "type" => "message",
            "channel_id" => channel,
            "message_ts" => message_ts
          },
          "message" => msg,
          "actions" => [Map.put(action, "action_ts", trigger_id())],
          "response_url" => Workspace.mint_response_url(ws, channel, message_ts),
          "trigger_id" => trigger_id()
        }

        dispatch(ws, info, envelope("interactive", payload))
      end
    end

    @doc "The human clicked an interactive element on a view (App Home or a modal)."
    def view_action(ws, view_id, action) do
      info = Workspace.info(ws)

      with {:ok, view} <- Workspace.fetch_view(ws, view_id) do
        payload = %{
          "type" => "block_actions",
          "user" => %{"id" => info.user_id, "username" => "you"},
          "team" => %{"id" => info.team_id},
          "container" => %{"type" => "view", "view_id" => view["id"]},
          "view" => view,
          "actions" => [Map.put(action, "action_ts", trigger_id())],
          "trigger_id" => trigger_id()
        }

        dispatch(ws, info, envelope("interactive", payload))
      end
    end

    @doc """
    The human submitted the modal `view_id`. Runs the handler synchronously
    (`Slink.Dispatcher.ack_result/3`, like a transport folding the ack into
    its reply), applies the returned `response_action` to the modal stack, and
    returns `{:ok, ack}` so the UI can render validation errors immediately.
    """
    def submit_view(ws, view_id, values) do
      info = Workspace.info(ws)

      with {:ok, view} <- Workspace.fetch_view(ws, view_id) do
        payload = %{
          "type" => "view_submission",
          "user" => %{"id" => info.user_id, "username" => "you"},
          "team" => %{"id" => info.team_id},
          "trigger_id" => trigger_id(),
          "view" => Map.put(view, "state", %{"values" => values})
        }

        env = envelope("interactive", payload)
        event = Event.from_socket_mode(env)
        ack = Dispatcher.ack_result(info.module, event, context(info))
        Workspace.log_inbound(ws, "view_submission", env, ack)
        :ok = Workspace.apply_ack(ws, view_id, ack)
        {:ok, ack}
      end
    end

    @doc """
    The human dismissed the modal `view_id`. Pops it; a view built with
    `notify_on_close` also dispatches the `view_closed` event, like Slack.
    """
    def close_view(ws, view_id) do
      info = Workspace.info(ws)

      with {:ok, view} <- Workspace.pop_view(ws, view_id) do
        if view["notify_on_close"] do
          payload = %{
            "type" => "view_closed",
            "user" => %{"id" => info.user_id, "username" => "you"},
            "team" => %{"id" => info.team_id},
            "view" => view,
            "is_cleared" => false
          }

          dispatch(ws, info, envelope("interactive", payload))
        end

        :ok
      end
    end

    @doc "The human toggled a reaction. `op` is \"add\" or \"remove\"."
    def user_reaction(ws, op, channel, ts, name) do
      info = Workspace.info(ws)

      with :ok <- Workspace.user_reaction(ws, op, channel, ts, name) do
        inner = %{
          "type" => "reaction_#{if op == "add", do: "added", else: "removed"}",
          "user" => info.user_id,
          "reaction" => name,
          "item" => %{"type" => "message", "channel" => channel, "ts" => ts},
          "item_user" => info.bot_user_id
        }

        dispatch(ws, info, event_callback(info, inner))
      end
    end

    @doc "The human opened the App Home tab."
    def home_opened(ws) do
      info = Workspace.info(ws)

      inner = %{
        "type" => "app_home_opened",
        "user" => info.user_id,
        "channel" => dm_id(info),
        "tab" => "home"
      }

      dispatch(ws, info, event_callback(info, inner))
    end

    @doc """
    Re-dispatch the envelope behind inspector entry `entry_id` verbatim — same
    event_id, so `Slink.Dedup` drops it exactly as it would a Slack retry.
    """
    def redeliver(ws, entry_id) do
      info = Workspace.info(ws)

      with {:ok, env} <- Workspace.envelope(ws, entry_id) do
        event = Event.from_socket_mode(env)

        if Dispatcher.sync_ack?(event) do
          # A modal submit must answer its ack; replaying one makes no sense.
          {:error, :not_redeliverable}
        else
          Workspace.log_inbound(ws, "#{event.type} (redelivered)", env)
          Dispatcher.async(info.module, event, context(info))
        end
      end
    end

    defp dispatch(ws, info, env) do
      event = Event.from_socket_mode(env)
      Workspace.log_inbound(ws, to_string(event.type), env)
      Dispatcher.async(info.module, event, context(info))
    end

    # Exactly the context the Socket Mode transport builds per event.
    defp context(info) do
      %Context{
        transport: :socket_mode,
        bot_token: info.bot_token,
        bot_user_id: Slink.Identity.bot_user_id(info.bot_token)
      }
    end

    defp event_callback(info, inner) do
      envelope("events_api", %{
        "type" => "event_callback",
        "event_id" => "EvPLAY#{System.unique_integer([:positive])}",
        "team_id" => info.team_id,
        "event" => inner
      })
    end

    defp envelope(type, payload) do
      %{
        "type" => type,
        "envelope_id" => "env-play-#{System.unique_integer([:positive])}",
        "payload" => payload
      }
    end

    defp trigger_id, do: "trigger-play-#{System.unique_integer([:positive])}"

    defp channel_type(info, channel) do
      if channel == dm_id(info), do: "im", else: "channel"
    end

    defp channel_name(info, channel) do
      Enum.find_value(info.channels, "", fn c -> c["id"] == channel && c["name"] end)
    end

    defp dm_id(info) do
      Enum.find_value(info.channels, fn c -> c["is_im"] && c["id"] end)
    end

    defp put_present(map, _key, nil), do: map
    defp put_present(map, key, value), do: Map.put(map, key, value)
  end
end
