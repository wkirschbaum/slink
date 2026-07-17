defmodule Slink.TestingTest do
  # async: false — run/3 swaps the process-global test seams.
  use ExUnit.Case, async: false
  import Slink.Testing

  alias Slink.Event

  defmodule EchoBot do
    use Slink

    @impl true
    def handle_event(%Event{type: :app_mention} = event, _context) do
      {:reply, "you said: #{Event.command(event)}"}
    end

    def handle_event(%Event{type: :slash_commands}, context) do
      reply(context, "on it", to: :channel)
    end

    def handle_event(%Event{type: :block_actions} = event, context) do
      update_original(context, "chose #{Event.action_value(event)}")
    end

    def handle_event(%Event{type: :view_submission}, _context) do
      {:ack, %{response_action: "clear"}}
    end

    def handle_event(%Event{type: :app_home_opened} = event, context) do
      case send_dm(context, Event.user(event), "welcome!") do
        :ok -> :ok
        {:error, reason} -> reply(context, "dm failed: #{inspect(reason)}")
      end
    end

    def handle_event(%Event{type: :shortcut}, context) do
      open_modal(context, %{"type" => "modal"})
    end

    def handle_event(_event, _context), do: :ok
  end

  describe "event/2 fixtures" do
    test "app_mention goes through the production normaliser" do
      event = event(:app_mention, text: "<@U1BOT> deploy", channel: "C9", thread_ts: "1.0")

      assert %Event{type: :app_mention, kind: :event_callback, transport: :socket_mode} = event
      assert Event.channel(event) == "C9"
      assert Event.command(event) == "deploy"
      assert Event.in_thread?(event)
      assert Event.team_id(event) == "T123"
      assert is_binary(Event.event_id(event))
    end

    test "slash_command carries command, response_url and trigger_id" do
      event = event(:slash_command, command: "/ship", text: "prod")

      assert %Event{type: :slash_commands, kind: :slash_commands} = event
      assert Event.command_name(event) == "/ship"
      assert Event.text(event) == "prod"
      assert Event.channel(event) == "C123"
      assert is_binary(Event.response_url(event))
      assert is_binary(Event.trigger_id(event))
    end

    test "block_actions surfaces action_id/value and the clicked message" do
      event = event(:block_actions, action_id: "approve", value: "42", thread_ts: "1.0")

      assert %Event{type: :block_actions, kind: :interactive} = event
      assert Event.action_id(event) == "approve"
      assert Event.action_value(event) == "42"
      assert Event.user(event) == "U123"
      assert Event.in_thread?(event)
    end

    test "view_submission carries callback_id and values" do
      values = %{"block" => %{"input" => %{"value" => "x"}}}
      event = event(:view_submission, callback_id: "settings", values: values)

      assert Event.callback_id(event) == "settings"
      assert Event.view_values(event) == values
    end

    test "reaction and home fixtures resolve channel/ts accessors" do
      reaction = event(:reaction_added, emoji: "tada", channel: "C7", ts: "9.9")
      assert Event.channel(reaction) == "C7"
      assert Event.ts(reaction) == "9.9"

      assert Event.channel(event(:app_home_opened)) == "C123"
    end

    test ":extra merges arbitrary payload keys" do
      event = event(:message, extra: %{"bot_id" => "B1"})
      assert Event.from_bot?(event)
    end
  end

  describe "run/3" do
    test "captures a return-style reply as a chat.postMessage" do
      run = run(EchoBot, event(:app_mention, text: "<@U1BOT> hi", channel: "C-t"))

      assert run.result == {:reply, "you said: hi"}
      assert [{"chat.postMessage", %{channel: "C-t", text: "you said: hi"}}] = run.calls
      assert run.responses == []
    end

    test "a threaded mention replies into the thread (to: :auto)" do
      run = run(EchoBot, event(:app_mention, text: "<@U1BOT> hi", thread_ts: "1.0"))

      assert [{"chat.postMessage", %{thread_ts: "1.0"}}] = run.calls
    end

    test "captures a slash reply on the response_url" do
      run = run(EchoBot, event(:slash_command, command: "/ship"))

      assert run.calls == []
      assert [%{text: "on it", response_type: "in_channel"}] = run.responses
    end

    test "captures update_original with replace_original" do
      run = run(EchoBot, event(:block_actions, value: "prod"))

      assert [%{text: "chose prod", replace_original: true}] = run.responses
    end

    test "returns the ack payload for a view_submission" do
      run = run(EchoBot, event(:view_submission))

      assert run.result == {:ack, %{response_action: "clear"}}
      assert run.calls == []
    end

    test "a {:reply, ...} from a view_submission is dropped, as production drops it" do
      defmodule WrongModalBot do
        use Slink

        @impl true
        def handle_event(%Event{type: :view_submission}, _context), do: {:reply, "ignored"}
      end

      # Production's sync-ack path never performs this reply — neither does run/3.
      run = run(WrongModalBot, event(:view_submission))

      assert run.result == {:reply, "ignored"}
      assert run.calls == []
      assert run.responses == []
    end

    test ":api also scripts response_url posts (pseudo-method \"response_url\")" do
      run =
        run(EchoBot, event(:slash_command),
          api: fn
            "response_url", _params -> {:error, {:http, 404, "no_service"}}
            _method, _params -> {:ok, %{"ok" => true}}
          end
        )

      # The reply attempt is still captured; the scripted failure is what the
      # handler's helper saw (reply/3 discards it — this proves the seam).
      assert [%{text: "on it"}] = run.responses
    end

    test "send_dm opens the conversation and posts into it" do
      run = run(EchoBot, event(:app_home_opened))

      assert [
               {"conversations.open", %{users: "U123"}},
               {"chat.postMessage", %{channel: "D-test", text: "welcome!"}}
             ] = run.calls
    end

    test "open_modal is captured with the default view response" do
      run = run(EchoBot, event(:shortcut))

      assert {:ok, %{"view" => %{"id" => "V-test"}}} = run.result
      assert [{"views.open", %{trigger_id: "trigger-test"}}] = run.calls
    end

    test ":api scripts failures so error paths are testable" do
      run =
        run(EchoBot, event(:app_home_opened),
          api: fn
            "conversations.open", _params -> {:error, "missing_scope"}
            _method, _params -> {:ok, %{"ok" => true}}
          end
        )

      # The bot's fallback reply after the failed DM is also captured.
      assert [
               {"conversations.open", _},
               {"chat.postMessage", %{text: "dm failed:" <> _}}
             ] = run.calls
    end

    test "bot_user_id makes mentions_me?/1 live in handlers" do
      defmodule MeBot do
        use Slink

        @impl true
        def handle_event(_event, context) do
          if mentions_me?(context), do: {:reply, "you rang"}, else: :ok
        end
      end

      mention = event(:message, text: "<@U1BOT> hello")

      assert %{calls: [{"chat.postMessage", _}]} =
               run(MeBot, mention, bot_user_id: "U1BOT")

      assert %{calls: []} = run(MeBot, mention, bot_user_id: "U9OTHER")
    end

    test "seams are restored after a run, even when the handler raises" do
      defmodule RaisingBot do
        use Slink

        @impl true
        def handle_event(_event, _context), do: raise("boom")
      end

      Application.put_env(:slink, :rate_sender, :sentinel)

      assert_raise RuntimeError, "boom", fn -> run(RaisingBot, event(:message)) end

      assert Application.get_env(:slink, :rate_sender) == :sentinel
      assert Application.get_env(:slink, :rate_mode, :async) == :async
      assert Application.get_env(:slink, :api_caller) == nil
      Application.delete_env(:slink, :rate_sender)
    end
  end
end
