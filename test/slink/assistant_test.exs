defmodule Slink.AssistantTest do
  # async: false — uses Slink.Testing.run/3 (global seams).
  use ExUnit.Case, async: false
  import Slink.Testing

  alias Slink.Event

  defmodule AssistantBot do
    use Slink

    @impl true
    def handle_event(%Event{type: :assistant_thread_started} = event, context) do
      set_status(context, "is warming up…")

      Slink.API.set_suggested_prompts(
        context.bot_token,
        Event.channel(event),
        Event.thread_ts(event),
        [%{title: "Summarise", message: "summarise this channel"}]
      )

      :ok
    end

    def handle_event(%Event{type: :message} = event, context) do
      # flush_ms: 0 → every chunk appends immediately, so tests see each one.
      stream_reply(context, ["Hello", " ", "world"], flush_ms: 0)
    end

    def handle_event(_event, _context), do: :ok
  end

  describe "assistant event fixtures and accessors" do
    test "assistant_thread_started resolves channel/user/thread from assistant_thread" do
      event = event(:assistant_thread_started, channel: "D9", user: "U9", thread_ts: "7.7")

      assert event.type == :assistant_thread_started
      assert Event.channel(event) == "D9"
      assert Event.user(event) == "U9"
      assert Event.thread_ts(event) == "7.7"
      # A reply threads under the assistant thread itself.
      assert Event.reply_thread(event) == "7.7"
    end

    test "assistant_thread_context_changed resolves the same way" do
      event = event(:assistant_thread_context_changed)

      assert event.type == :assistant_thread_context_changed
      assert Event.channel(event) == "D123"
    end
  end

  describe "set_status/2 and suggested prompts" do
    test "a thread-started handler sets status and prompts" do
      run = run(AssistantBot, event(:assistant_thread_started, channel: "D9", thread_ts: "7.7"))

      assert [
               {"assistant.threads.setStatus",
                %{channel_id: "D9", thread_ts: "7.7", status: "is warming up…"}},
               {"assistant.threads.setSuggestedPrompts",
                %{channel_id: "D9", prompts: [%{title: "Summarise"} | _]}}
             ] = run.calls
    end
  end

  describe "stream_reply/3" do
    test "starts, appends each flushed chunk, and stops" do
      run = run(AssistantBot, event(:message, channel: "D9", thread_ts: "7.7"))

      assert [
               {"chat.startStream", %{channel: "D9", thread_ts: "7.7"}},
               {"chat.appendStream", %{ts: "S-test", markdown_text: "Hello"}},
               {"chat.appendStream", %{markdown_text: " "}},
               {"chat.appendStream", %{markdown_text: "world"}},
               {"chat.stopStream", %{ts: "S-test"} = stop}
             ] = run.calls

      refute Map.has_key?(stop, :markdown_text)
      assert run.result == {:ok, "S-test"}
    end

    test "with a slow flush interval, everything lands in the final stop" do
      defmodule SlowFlushBot do
        use Slink

        @impl true
        def handle_event(_event, context) do
          stream_reply(context, ["a", "b", "c"], flush_ms: 60_000)
        end
      end

      run = run(SlowFlushBot, event(:message))

      assert [
               {"chat.startStream", _},
               {"chat.stopStream", %{markdown_text: "abc"}}
             ] = run.calls
    end

    test "degrades to a single post when streaming isn't available" do
      run =
        run(AssistantBot, event(:message, channel: "D9", thread_ts: "7.7"),
          api: fn
            "chat.startStream", _params -> {:error, "unknown_method"}
            "chat.postMessage", _params -> {:ok, %{"ok" => true, "ts" => "1.5"}}
          end
        )

      assert [
               {"chat.startStream", _},
               {"chat.postMessage", %{channel: "D9", text: "Hello world", thread_ts: "7.7"}}
             ] = run.calls

      assert run.result == {:ok, "1.5"}
    end

    test "a failed append keeps its text buffered for the stop" do
      run =
        run(AssistantBot, event(:message),
          api: fn
            "chat.startStream", _ -> {:ok, %{"ok" => true, "ts" => "S1"}}
            "chat.appendStream", _ -> {:error, "ratelimited"}
            "chat.stopStream", _ -> {:ok, %{"ok" => true}}
          end
        )

      # Appends were attempted but failed; nothing is lost — the whole text
      # rides out on stop_stream.
      assert {"chat.stopStream", %{markdown_text: "Hello world"}} = List.last(run.calls)
    end

    test "a single oversized chunk is appended in capped slices, never one over-cap call" do
      defmodule BigChunkBot do
        use Slink

        @impl true
        def handle_event(_event, context) do
          stream_reply(context, [String.duplicate("a", 20_000)], flush_ms: 0)
        end
      end

      run = run(BigChunkBot, event(:message))

      appends =
        for {"chat.appendStream", %{markdown_text: text}} <- run.calls, do: String.length(text)

      # 20k splits into 12k + 8k — no single append exceeds Slack's cap, and
      # nothing is lost.
      assert appends == [12_000, 8_000]
      assert Enum.all?(appends, &(&1 <= 12_000))
    end

    test "leftover text prepends to a user-supplied finish markdown_text, never clobbering it" do
      defmodule FinishBot do
        use Slink

        @impl true
        def handle_event(_event, context) do
          stream_reply(context, ["abc"], flush_ms: 60_000, finish: %{markdown_text: " END"})
        end
      end

      run = run(FinishBot, event(:message))

      assert {"chat.stopStream", %{markdown_text: "abc END"}} = List.last(run.calls)
    end

    test "raises for an event with no channel/thread to stream into" do
      assert_raise ArgumentError, ~r/stream_reply/, fn ->
        Slink.stream_reply(context(event(:shortcut)), ["x"])
      end
    end
  end

  describe "API wrappers against the fake Web API" do
    setup do
      {:ok, base_url, pid} = Slink.Test.FakeWebApi.start()
      Application.put_env(:slink, :api_base_url, base_url)

      on_exit(fn ->
        Application.delete_env(:slink, :api_base_url)
        Process.exit(pid, :normal)
      end)

      :ok
    end

    test "assistant thread methods and the streaming trio succeed" do
      assert {:ok, _} = Slink.API.set_thread_status("xoxb", "D1", "1.0", "thinking…")
      assert {:ok, _} = Slink.API.set_thread_title("xoxb", "D1", "1.0", "Q&A")

      assert {:ok, _} =
               Slink.API.set_suggested_prompts("xoxb", "D1", "1.0", [
                 %{title: "Hi", message: "hi"}
               ])

      assert {:ok, %{"ts" => ts}} = Slink.API.start_stream("xoxb", "D1", "1.0")
      assert {:ok, _} = Slink.API.append_stream("xoxb", "D1", ts, "chunk")
      assert {:ok, _} = Slink.API.stop_stream("xoxb", "D1", ts, %{markdown_text: "done"})
    end
  end
end
