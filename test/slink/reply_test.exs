defmodule Slink.ReplyTest do
  use ExUnit.Case, async: false

  alias Slink.{Context, Event}

  defmodule Bot do
    use Slink

    @impl true
    def handle_event(event, context) do
      reply(context, event, "pong")
      :ok
    end
  end

  setup do
    test_pid = self()

    Application.put_env(:slink, :rate_sender, fn _token, _method, params ->
      send(test_pid, {:sent, params})
      {:ok, %{"ok" => true}}
    end)

    on_exit(fn -> Application.delete_env(:slink, :rate_sender) end)
    :ok
  end

  defp context, do: %Context{transport: :socket_mode, bot_token: "xoxb"}

  test "reply/3 threads under the event's existing thread_ts" do
    event = %Event{
      type: "app_mention",
      payload: %{"channel" => "C-reply-a", "ts" => "2.0", "thread_ts" => "1.0"},
      raw: %{},
      transport: :socket_mode
    }

    Bot.handle_event(event, context())

    assert_receive {:sent, %{channel: "C-reply-a", text: "pong", thread_ts: "1.0"}}, 1_000
  end

  test "reply/3 starts a thread on the triggering message when not already threaded" do
    event = %Event{
      type: "app_mention",
      payload: %{"channel" => "C-reply-b", "ts" => "2.0"},
      raw: %{},
      transport: :socket_mode
    }

    Bot.handle_event(event, context())

    assert_receive {:sent, %{channel: "C-reply-b", thread_ts: "2.0"}}, 1_000
  end

  test "explicit thread_ts in opts is not overridden" do
    event = %Event{
      payload: %{"channel" => "C-reply-c", "ts" => "2.0"},
      raw: %{},
      transport: :socket_mode
    }

    assert :ok = Slink.reply(context(), event, "pong", %{thread_ts: "9.9"})
    assert_receive {:sent, %{thread_ts: "9.9"}}, 1_000
  end
end
