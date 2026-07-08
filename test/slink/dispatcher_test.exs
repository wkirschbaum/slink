defmodule Slink.DispatcherTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Slink.{Context, Dispatcher, Event}

  defmodule GoodBot do
    use Slink

    @impl true
    def handle_event(event, _context) do
      send(:dispatcher_sink, {:handled, event.type})
      :ok
    end
  end

  defmodule CrashBot do
    use Slink

    @impl true
    def handle_event(_event, _context), do: raise("boom")
  end

  defmodule NoCallbackBot do
  end

  setup do
    Process.register(self(), :dispatcher_sink)
    :ok
  end

  defp event, do: %Event{type: "app_mention", payload: %{}, raw: %{}, transport: :socket_mode}
  defp context, do: %Context{transport: :socket_mode, bot_token: nil}

  test "invokes the module's handle_event/2" do
    assert :ok = Dispatcher.dispatch(GoodBot, event(), context())
    assert_received {:handled, "app_mention"}
  end

  test "lets a handler crash propagate (containment is the task's job, not a rescue)" do
    assert_raise RuntimeError, "boom", fn ->
      Dispatcher.dispatch(CrashBot, event(), context())
    end
  end

  test "loads the handler module before checking for handle_event/2" do
    # Simulate lazy code loading: the module exists on disk but isn't in memory,
    # which is the normal state when the bot is only referenced as `module: Bot`
    # in config and the first Slack event arrives. `function_exported?/3` reports
    # false for an unloaded module, so dispatch must load it first.
    :code.purge(Slink.Test.LazyBot)
    :code.delete(Slink.Test.LazyBot)
    refute function_exported?(Slink.Test.LazyBot, :handle_event, 2)

    assert :ok = Dispatcher.dispatch(Slink.Test.LazyBot, event(), context())
    assert_received {:lazy_handled, "app_mention"}
  end

  test "warns and returns :ok when the module has no handle_event/2" do
    log =
      capture_log(fn ->
        assert :ok = Dispatcher.dispatch(NoCallbackBot, event(), context())
      end)

    assert log =~ "does not implement handle_event/2"
  end

  # Named handler (captured function) avoids telemetry's local-fn perf warning.
  def forward_telemetry(_event, _measurements, metadata, parent) do
    send(parent, {:telemetry, metadata})
  end

  test "async/3 runs the handler off-process and emits a telemetry event" do
    handler = "test-#{inspect(self())}"

    :telemetry.attach(
      handler,
      [:slink, :event, :received],
      &__MODULE__.forward_telemetry/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Dispatcher.async(GoodBot, event(), context())

    assert_receive {:telemetry, %{type: "app_mention", transport: :socket_mode, module: GoodBot}},
                   1_000

    assert_receive {:handled, "app_mention"}, 1_000
  end
end
