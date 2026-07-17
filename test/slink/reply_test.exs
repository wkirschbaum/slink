defmodule Slink.ReplyTest do
  use ExUnit.Case, async: false

  alias Slink.{Context, Dispatcher, Event}

  defmodule ReturnBot do
    use Slink

    @impl true
    def handle_event(_event, _context), do: {:reply, "pong"}
  end

  defmodule RichReturnBot do
    use Slink

    @impl true
    def handle_event(_event, _context),
      do: {:reply, "fallback", to: :channel, blocks: [%{type: "section"}]}
  end

  defmodule SilentBot do
    use Slink

    @impl true
    def handle_event(_event, _context), do: :ok
  end

  setup do
    test_pid = self()

    # Tiny interval so the per-channel rate limiter doesn't serialize sends.
    Application.put_env(:slink, :rate_interval_ms, 1)

    Application.put_env(:slink, :rate_sender, fn _token, _method, params ->
      send(test_pid, {:sent, params})
      {:ok, %{"ok" => true}}
    end)

    on_exit(fn ->
      Application.delete_env(:slink, :rate_sender)
      Application.delete_env(:slink, :rate_interval_ms)
    end)

    :ok
  end

  # A distinct channel per test keeps each test's messages on its own rate worker.
  defp event(channel, extra \\ %{}) do
    %Event{
      type: :app_mention,
      payload: Map.merge(%{"channel" => channel, "ts" => "2.0"}, extra),
      raw: %{},
      transport: :socket_mode
    }
  end

  # Context with the event embedded (as the dispatcher sets it before a handler).
  defp context(event),
    do: %Context{transport: :socket_mode, bot_token: "xoxb", event: event}

  describe "reply/3 placement (:to)" do
    test ":auto (default) threads when the event is already in a thread" do
      Slink.reply(context(event("C-auto-thread", %{"thread_ts" => "1.0"})), "hi")
      assert_receive {:sent, %{channel: "C-auto-thread", text: "hi", thread_ts: "1.0"}}, 1_000
    end

    test ":auto (default) posts inline when the event is not in a thread" do
      Slink.reply(context(event("C-auto-inline")), "hi")
      assert_receive {:sent, %{channel: "C-auto-inline", text: "hi"} = params}, 1_000
      refute Map.has_key?(params, :thread_ts)
    end

    test ":thread starts a thread on a non-threaded message" do
      Slink.reply(context(event("C-thread")), "hi", to: :thread)
      assert_receive {:sent, %{channel: "C-thread", thread_ts: "2.0"}}, 1_000
    end

    test ":channel posts inline even when the event is inside a thread" do
      Slink.reply(context(event("C-channel", %{"thread_ts" => "1.0"})), "hi", to: :channel)
      assert_receive {:sent, %{channel: "C-channel", text: "hi"} = params}, 1_000
      refute Map.has_key?(params, :thread_ts)
    end

    test "merges extra opts into the body for rich replies" do
      Slink.reply(context(event("C-rich")), "hi", to: :channel, blocks: [%{type: "section"}])

      assert_receive {:sent, %{channel: "C-rich", text: "hi", blocks: [%{type: "section"}]}},
                     1_000
    end

    test "an explicit thread_ts in opts is not overridden" do
      Slink.reply(context(event("C-explicit")), "hi", to: :thread, thread_ts: "9.9")
      assert_receive {:sent, %{thread_ts: "9.9"}}, 1_000
    end

    test "returns :ok" do
      assert :ok = Slink.reply(context(event("C-ok")), "hi")
    end

    test ":thread with no timestamp to thread under does not send a nil thread_ts" do
      event = %Event{
        type: :app_mention,
        payload: %{"channel" => "C-no-ts"},
        raw: %{},
        transport: :socket_mode
      }

      Slink.reply(context(event), "hi", to: :thread)
      assert_receive {:sent, %{channel: "C-no-ts", text: "hi"} = params}, 1_000
      refute Map.has_key?(params, :thread_ts)
    end

    test "raises a clear error when the context carries no event" do
      ctx = %Context{transport: :socket_mode, bot_token: "xoxb", event: nil}
      assert_raise ArgumentError, ~r/requires context.event/, fn -> Slink.reply(ctx, "hi") end
    end
  end

  describe "send_message/4" do
    test "accepts keyword opts (like reply/3), not just a map" do
      assert :ok =
               Slink.send_message(context(event("C-sm")), "C-sm", "hi",
                 thread_ts: "1.0",
                 blocks: [%{type: "section"}]
               )

      assert_receive {:sent,
                      %{
                        channel: "C-sm",
                        text: "hi",
                        thread_ts: "1.0",
                        blocks: [%{type: "section"}]
                      }},
                     1_000
    end

    test "still accepts a map for backward compatibility" do
      assert :ok = Slink.send_message(context(event("C-sm2")), "C-sm2", "hi", %{thread_ts: "9.9"})
      assert_receive {:sent, %{channel: "C-sm2", text: "hi", thread_ts: "9.9"}}, 1_000
    end
  end

  describe "reply/3 to a block_actions interaction" do
    defp click(channel, message) do
      %Event{
        type: :interactive,
        kind: :interactive,
        payload: %{
          "type" => "block_actions",
          "channel" => %{"id" => channel},
          "message" => message
        },
        raw: %{},
        transport: :socket_mode
      }
    end

    test ":auto (default) threads a click made inside a thread" do
      event = click("C-click-thread", %{"ts" => "2.0", "thread_ts" => "1.0"})
      Slink.reply(context(event), "clicked")

      assert_receive {:sent, %{channel: "C-click-thread", text: "clicked", thread_ts: "1.0"}},
                     1_000
    end

    test ":auto (default) answers a click on a top-level message in the channel" do
      event = click("C-click-inline", %{"ts" => "2.0"})
      Slink.reply(context(event), "clicked")
      assert_receive {:sent, %{channel: "C-click-inline", text: "clicked"} = params}, 1_000
      refute Map.has_key?(params, :thread_ts)
    end

    test ":thread forces a thread on a click on a top-level message" do
      event = click("C-click-force", %{"ts" => "2.0"})
      Slink.reply(context(event), "clicked", to: :thread)
      assert_receive {:sent, %{channel: "C-click-force", thread_ts: "2.0"}}, 1_000
    end
  end

  describe "reply/3 with to: :ephemeral on a plain event" do
    test "posts a chat.postEphemeral to the triggering user" do
      test_pid = self()

      Application.put_env(:slink, :rate_sender, fn _token, method, params ->
        send(test_pid, {:sent, method, params})
        {:ok, %{"ok" => true}}
      end)

      event = event("C-eph", %{"user" => "U-asker"})
      assert :ok = Slink.reply(context(event), "just for you", to: :ephemeral)

      assert_receive {:sent, "chat.postEphemeral",
                      %{channel: "C-eph", user: "U-asker", text: "just for you"}},
                     1_000
    end

    test "raises a clear error when the event has no user to address" do
      event = event("C-eph-nouser")

      assert_raise ArgumentError, ~r/to: :ephemeral/, fn ->
        Slink.reply(context(event), "hi", to: :ephemeral)
      end
    end
  end

  describe "mentions_me?/1" do
    test "true only when the bot's own id is mentioned and known" do
      event = event("C-me", %{"text" => "<@U111ME> and <@U222OTHER>"})

      me = %Context{
        transport: :socket_mode,
        bot_token: "xoxb",
        bot_user_id: "U111ME",
        event: event
      }

      assert Slink.mentions_me?(me)
      refute Slink.mentions_me?(%{me | bot_user_id: "U333ELSE"})
      # Identity not discovered yet — never a false positive, never a crash.
      refute Slink.mentions_me?(%{me | bot_user_id: nil})
      refute Slink.mentions_me?(%{me | event: nil})
    end
  end

  describe "handler return values (via Dispatcher)" do
    # Dispatcher embeds the event into the context, so pass a context without one.
    defp bare_context, do: %Context{transport: :socket_mode, bot_token: "xoxb"}

    test "{:reply, text} sends an auto-placed reply" do
      Dispatcher.dispatch(ReturnBot, event("C-ret"), bare_context())
      assert_receive {:sent, %{channel: "C-ret", text: "pong"} = params}, 1_000
      refute Map.has_key?(params, :thread_ts)
    end

    test "{:reply, text, opts} passes placement and rich blocks through" do
      Dispatcher.dispatch(
        RichReturnBot,
        event("C-dispatch-rich", %{"thread_ts" => "1.0"}),
        bare_context()
      )

      assert_receive {:sent,
                      %{
                        channel: "C-dispatch-rich",
                        text: "fallback",
                        blocks: [%{type: "section"}]
                      } =
                        params},
                     1_000

      # to: :channel overrides the event's thread.
      refute Map.has_key?(params, :thread_ts)
    end

    test ":ok sends nothing" do
      Dispatcher.dispatch(SilentBot, event("C-silent"), bare_context())
      refute_receive {:sent, _}, 200
    end
  end
end
