defmodule Slink.Testing do
  @moduledoc """
  Unit-test your bot's `c:Slink.handle_event/2` without Slack.

  Two pieces: `event/2` builds realistic event fixtures (through the same
  normaliser the Socket Mode transport uses, so shapes can't drift from
  production), and `run/3` executes your handler with every Slack call
  captured instead of sent:

      defmodule MyBotTest do
        # run/3 swaps process-global test seams — keep these tests async: false.
        use ExUnit.Case, async: false
        import Slink.Testing

        test "greets a mention in its thread" do
          run = run(MyBot, event(:app_mention, text: "<@U1BOT> hi", thread_ts: "1.0"))

          assert [{"chat.postMessage", %{text: "hi" <> _, thread_ts: "1.0"}}] = run.calls
        end

        test "a slash command is answered ephemerally" do
          run = run(MyBot, event(:slash_command, command: "/deploy", text: "prod"))

          assert [%{response_type: "ephemeral"}] = run.responses
        end
      end

  `run/3` is fully synchronous: the handler runs in the test process, sends
  bypass the rate-limit workers, and by the time it returns, `run.calls` and
  `run.responses` hold everything the bot did, in order. A handler that raises
  bubbles into the test, where you want it.

  Failure paths are testable by scripting the fake API with `:api`:

      run = run(MyBot, event(:app_mention), api: fn
        "chat.postMessage", _params -> {:error, "channel_not_found"}
        _method, _params -> {:ok, %{"ok" => true}}
      end)
  """

  alias Slink.{Context, Dispatcher, Event}

  defmodule Run do
    @moduledoc """
    What a `Slink.Testing.run/3` observed.

      * `:result` — the handler's raw return value (`:ok`, `{:reply, …}`,
        `{:ack, …}`, …). The reply, if any, was also performed and captured.
      * `:calls` — Web API calls, in order, as `{method, params}` tuples. The
        params' *top-level* keys are atoms (e.g. `{"chat.postMessage",
        %{channel: "C123", …}}`); nested maps keep whatever keys the handler
        built them with.
      * `:responses` — bodies posted to a `response_url` (slash replies,
        `update_original/3`), in order.
    """
    defstruct result: nil, calls: [], responses: []
  end

  @default_channel "C123"
  @default_user "U123"
  @default_ts "1700000000.000100"
  @default_team "T123"
  @default_response_url "https://hooks.slack.com/actions/T123/456/test"

  @doc """
  Build a `Slink.Event` fixture of the given `type`.

  The fixture is assembled as a Socket Mode envelope and normalised by
  `Slink.Event.from_socket_mode/1` — the exact production path. Common
  attributes (all optional, with sensible defaults): `:channel`, `:user`,
  `:ts`, `:text`, `:thread_ts`, `:team_id`. Anything under `:extra` (a map of
  string keys) is merged into the inner payload for shapes not covered here.

  Supported types and their specific attributes:

    * `:app_mention`, `:message` — `:text`, `:thread_ts`, `:subtype`,
      `:event_id`. A `"message_changed"` / `"message_deleted"` subtype builds
      the nested shape Slack really sends (your attrs describe the nested
      message; the wrapper gets its own edit-event `ts`), so the accessors
      behave as they do in production.
    * `:reaction_added` / `:reaction_removed` — `:emoji` (default `"eyes"`)
    * `:app_home_opened` — `:user`
    * `:slash_command` (or `:slash_commands`) — `:command` (default
      `"/slink"`), `:text`, `:response_url`, `:trigger_id`
    * `:block_actions` — `:action_id` (default `"button"`), `:value`,
      `:message_ts`, `:thread_ts`, `:response_url`, `:trigger_id`
    * `:view_submission` — `:callback_id`, `:values` (the modal's
      `state.values` map), `:trigger_id`
    * `:shortcut`, `:message_action` — `:callback_id`, `:trigger_id`
    * `:assistant_thread_started`, `:assistant_thread_context_changed` —
      `:channel` (the assistant DM), `:thread_ts`, `:user`
  """
  def event(type, attrs \\ [])

  def event(type, attrs) when type in [:app_mention, :message] do
    inner =
      %{
        "type" => Atom.to_string(type),
        "user" => attrs[:user] || @default_user,
        "channel" => attrs[:channel] || @default_channel,
        "ts" => attrs[:ts] || @default_ts,
        "text" => attrs[:text] || ""
      }
      |> put_present("thread_ts", attrs[:thread_ts])

    event_callback(nest_subtype(inner, attrs[:subtype]), attrs)
  end

  def event(type, attrs) when type in [:reaction_added, :reaction_removed] do
    inner = %{
      "type" => Atom.to_string(type),
      "user" => attrs[:user] || @default_user,
      "reaction" => attrs[:emoji] || "eyes",
      "item" => %{
        "type" => "message",
        "channel" => attrs[:channel] || @default_channel,
        "ts" => attrs[:ts] || @default_ts
      }
    }

    event_callback(inner, attrs)
  end

  def event(type, attrs)
      when type in [:assistant_thread_started, :assistant_thread_context_changed] do
    inner = %{
      "type" => Atom.to_string(type),
      "assistant_thread" => %{
        "user_id" => attrs[:user] || @default_user,
        "channel_id" => attrs[:channel] || "D123",
        "thread_ts" => attrs[:thread_ts] || @default_ts,
        "context" => %{"channel_id" => nil, "team_id" => attrs[:team_id] || @default_team}
      }
    }

    event_callback(inner, attrs)
  end

  def event(:app_home_opened, attrs) do
    inner = %{
      "type" => "app_home_opened",
      "user" => attrs[:user] || @default_user,
      "channel" => attrs[:channel] || @default_channel,
      "tab" => "home"
    }

    event_callback(inner, attrs)
  end

  # The canonical name matches the event type handlers pattern-match on
  # (:slash_commands); the singular reads naturally too, so both are accepted.
  def event(:slash_commands, attrs), do: event(:slash_command, attrs)

  def event(:slash_command, attrs) do
    payload =
      %{
        "command" => attrs[:command] || "/slink",
        "text" => attrs[:text] || "",
        "channel_id" => attrs[:channel] || @default_channel,
        "user_id" => attrs[:user] || @default_user,
        "team_id" => attrs[:team_id] || @default_team,
        "response_url" => attrs[:response_url] || @default_response_url,
        "trigger_id" => attrs[:trigger_id] || "trigger-test"
      }
      |> merge_extra(attrs)

    envelope("slash_commands", payload)
  end

  def event(:block_actions, attrs) do
    message =
      %{"ts" => attrs[:message_ts] || @default_ts}
      |> put_present("thread_ts", attrs[:thread_ts])

    payload =
      %{
        "type" => "block_actions",
        "user" => %{"id" => attrs[:user] || @default_user},
        "team" => %{"id" => attrs[:team_id] || @default_team},
        "channel" => %{"id" => attrs[:channel] || @default_channel},
        "message" => message,
        "actions" => [
          %{
            "type" => "button",
            "action_id" => attrs[:action_id] || "button",
            "value" => attrs[:value] || "value"
          }
        ],
        "response_url" => attrs[:response_url] || @default_response_url,
        "trigger_id" => attrs[:trigger_id] || "trigger-test"
      }
      |> merge_extra(attrs)

    envelope("interactive", payload)
  end

  def event(:view_submission, attrs) do
    payload =
      %{
        "type" => "view_submission",
        "user" => %{"id" => attrs[:user] || @default_user},
        "team" => %{"id" => attrs[:team_id] || @default_team},
        "trigger_id" => attrs[:trigger_id] || "trigger-test",
        "view" => %{
          "id" => "V-test",
          "callback_id" => attrs[:callback_id] || "modal",
          "state" => %{"values" => attrs[:values] || %{}}
        }
      }
      |> merge_extra(attrs)

    envelope("interactive", payload)
  end

  def event(type, attrs) when type in [:shortcut, :message_action] do
    payload =
      %{
        "type" => Atom.to_string(type),
        "callback_id" => attrs[:callback_id] || "shortcut",
        "user" => %{"id" => attrs[:user] || @default_user},
        "team" => %{"id" => attrs[:team_id] || @default_team},
        "trigger_id" => attrs[:trigger_id] || "trigger-test"
      }
      |> merge_extra(attrs)

    envelope("interactive", payload)
  end

  # message_changed / message_deleted nest the real message, exactly as Slack
  # sends them — so a fixture like `event(:message, subtype: "message_changed",
  # text: "edited")` behaves under the accessors the way production payloads
  # do. Other subtypes (bot_message, …) are flat on the wire and stay flat.
  defp nest_subtype(inner, nil), do: inner

  defp nest_subtype(inner, "message_changed") do
    %{
      "type" => "message",
      "subtype" => "message_changed",
      "channel" => inner["channel"],
      # The wrapper's own ts is the edit event's timestamp, not the message's.
      "ts" => "9999999999.000001",
      "message" => Map.drop(inner, ["channel"])
    }
  end

  defp nest_subtype(inner, "message_deleted") do
    %{
      "type" => "message",
      "subtype" => "message_deleted",
      "channel" => inner["channel"],
      "ts" => "9999999999.000001",
      "deleted_ts" => inner["ts"],
      "previous_message" => Map.drop(inner, ["channel"])
    }
  end

  defp nest_subtype(inner, subtype), do: Map.put(inner, "subtype", subtype)

  defp event_callback(inner, attrs) do
    envelope("events_api", %{
      "type" => "event_callback",
      "event_id" => attrs[:event_id] || "Ev-test-#{System.unique_integer([:positive])}",
      "team_id" => attrs[:team_id] || @default_team,
      "event" => merge_extra(inner, attrs)
    })
  end

  defp envelope(type, payload) do
    Event.from_socket_mode(%{
      "type" => type,
      "envelope_id" => "env-test-#{System.unique_integer([:positive])}",
      "payload" => payload
    })
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp merge_extra(map, attrs), do: Map.merge(map, attrs[:extra] || %{})

  @doc """
  A handler context for `event`, as the dispatcher would build it.

  Options: `:bot_token` (default `"xoxb-test"`), `:bot_user_id` (default
  `nil` — set it to make `mentions_me?/1` live).
  """
  def context(%Event{} = event, opts \\ []) do
    %Context{
      transport: event.transport,
      bot_token: Keyword.get(opts, :bot_token, "xoxb-test"),
      bot_user_id: Keyword.get(opts, :bot_user_id),
      event: event
    }
  end

  @doc """
  Run `module`'s handler for `event`, capturing every Slack call.

  Returns a `Slink.Testing.Run` — the handler's `result` plus the `calls` and
  `responses` it produced (including a `{:reply, …}` return value, which is
  performed exactly as the dispatcher would — so for a `view_submission` it is
  *dropped*, as production's sync-ack path drops it). Everything is
  synchronous and in-process; nothing touches the network.

  Options: `:bot_token` / `:bot_user_id` (see `context/2`), and `:api` — a
  2-arity function `(method, params)` deciding what each Web API call returns
  (default: success shapes), for exercising failure paths. Posts to a
  `response_url` reach it as the pseudo-method `"response_url"`.

  This works by swapping Slink's process-global test seams for the duration of
  the call, so tests using `run/3` must be `async: false`.
  """
  def run(module, %Event{} = event, opts \\ []) do
    owner = self()
    ref = make_ref()
    api = Keyword.get(opts, :api, &default_api/2)

    seams = [
      rate_mode: :sync,
      rate_sender: fn _token, method, params ->
        send(owner, {ref, :call, {method, atomize(params)}})
        api.(method, params)
      end,
      api_caller: fn _token, method, params ->
        send(owner, {ref, :call, {method, atomize(params)}})
        api.(method, params)
      end,
      api_responder: fn _url, params ->
        send(owner, {ref, :response, atomize(params)})
        api.("response_url", params)
      end,
      # Byte uploads (Slink.API.upload_file/3) are swallowed; assert on the
      # getUploadURLExternal/completeUploadExternal calls around them instead.
      api_uploader: fn _url, _content -> :ok end
    ]

    previous = swap_seams(seams)
    # `after` restores on any raise/throw/exit *inside* the block — but not on
    # an external :kill, which is exactly what an ExUnit test *timeout*
    # delivers. Register a second, idempotent restore through on_exit (it runs
    # in a separate process), so a hung handler can't leave the seams swapped
    # for the rest of the suite. Outside ExUnit, on_exit raises — ignore.
    try do
      ExUnit.Callbacks.on_exit(fn -> restore_seams(previous) end)
    rescue
      _not_in_a_test -> :ok
    end

    try do
      context = %{context(event, opts) | event: event}
      result = module.handle_event(event, context)

      # Production drops a {:reply, …} from a view_submission (its sync-ack
      # path answers with {:ack, …} only) — mirror that instead of performing
      # a reply that would raise here but be a logged no-op live.
      unless Dispatcher.sync_ack?(event) do
        Dispatcher.perform_reply(result, context)
      end

      %Run{result: result, calls: collect(ref, :call), responses: collect(ref, :response)}
    after
      restore_seams(previous)
    end
  end

  # Sensible success shapes for the calls helpers make, so a handler using
  # open_modal/2, send_dm/4 or upload_file/3 works out of the box. Script
  # `:api` to override.
  defp default_api("views." <> _, _params),
    do: {:ok, %{"ok" => true, "view" => %{"id" => "V-test"}}}

  defp default_api("conversations.open", _params),
    do: {:ok, %{"ok" => true, "channel" => %{"id" => "D-test"}}}

  defp default_api("files.getUploadURLExternal", _params),
    do:
      {:ok,
       %{"ok" => true, "upload_url" => "https://files.slack.com/test", "file_id" => "F-test"}}

  defp default_api("chat.startStream", _params),
    do: {:ok, %{"ok" => true, "ts" => "S-test", "channel" => "C123"}}

  defp default_api(_method, _params), do: {:ok, %{"ok" => true}}

  # Params built by Slink's helpers are atom-keyed already; normalise any
  # string keys a direct Slink.API call might carry so assertions are uniform.
  defp atomize(params) do
    Map.new(params, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      pair -> pair
    end)
  end

  defp swap_seams(seams) do
    for {key, value} <- seams do
      previous = Application.fetch_env(:slink, key)
      Application.put_env(:slink, key, value)
      {key, previous}
    end
  end

  defp restore_seams(previous) do
    for {key, prev} <- previous do
      case prev do
        {:ok, value} -> Application.put_env(:slink, key, value)
        :error -> Application.delete_env(:slink, key)
      end
    end
  end

  defp collect(ref, kind, acc \\ []) do
    receive do
      {^ref, ^kind, item} -> collect(ref, kind, [item | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
