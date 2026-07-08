defmodule Slink.ExampleBotTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Slink.{Dispatcher, Event}

  setup do
    test_pid = self()

    Application.put_env(:slink, :rate_sender, fn token, method, params ->
      send(test_pid, {:sent, token, method, params})
      {:ok, %{"ok" => true}}
    end)

    on_exit(fn -> Application.delete_env(:slink, :rate_sender) end)
    :ok
  end

  test "replies to an app_mention (dispatcher sends the returned reply)" do
    event = %Event{
      type: "app_mention",
      payload: %{"channel" => "C-example", "user" => "U1"},
      raw: %{},
      transport: :socket_mode
    }

    context = %Slink.Context{transport: :socket_mode, bot_token: "xoxb-t"}

    # The handler just returns the reply; the dispatcher performs the send.
    assert {:reply, text} = Slink.ExampleBot.handle_event(event, context)
    assert text =~ "hi <@U1>"

    Dispatcher.dispatch(Slink.ExampleBot, event, context)

    assert_receive {:sent, "xoxb-t", "chat.postMessage", %{channel: "C-example", text: ^text}},
                   1_000
  end

  test "ignores and logs other event types" do
    event = %Event{type: "reaction_added", payload: %{}, raw: %{}, transport: :http}

    context = %Slink.Context{transport: :http, bot_token: nil}

    log =
      capture_log([level: :debug], fn ->
        assert :ok = Slink.ExampleBot.handle_event(event, context)
      end)

    assert log =~ "unhandled event"
  end
end
