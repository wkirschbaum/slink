defmodule Slink.DedupTest do
  # async: false — toggles the :dedup app env and shares the global dedup table.
  use ExUnit.Case, async: false

  alias Slink.{Context, Dedup, Dispatcher, Event}

  defp id, do: "Ev-#{System.unique_integer([:positive])}"

  test "seen?/1 is false the first time and true on a repeat" do
    key = id()
    refute Dedup.seen?(key)
    assert Dedup.seen?(key)
    assert Dedup.seen?(key)
  end

  test "distinct ids are tracked independently" do
    a = id()
    b = id()
    refute Dedup.seen?(a)
    refute Dedup.seen?(b)
    assert Dedup.seen?(a)
    assert Dedup.seen?(b)
  end

  test "fails open (always false) when disabled" do
    Application.put_env(:slink, :dedup, false)
    on_exit(fn -> Application.delete_env(:slink, :dedup) end)

    key = id()
    refute Dedup.seen?(key)
    refute Dedup.seen?(key)
  end

  test "the periodic sweep evicts entries past their TTL" do
    live = id()
    # An already-expired entry (expiry in the past) alongside a live one.
    expired = id()
    :ets.insert(Dedup, {expired, System.monotonic_time(:millisecond) - 1000})
    refute Dedup.seen?(live)

    send(Dedup, :sweep)
    # Sync on the process so the sweep has run before we assert.
    :sys.get_state(Dedup)

    assert :ets.lookup(Dedup, expired) == []
    assert :ets.lookup(Dedup, live) != []
  end

  defmodule OnceBot do
    use Slink

    @impl true
    def handle_event(event, _context) do
      send(:dedup_sink, {:handled, event.type, Slink.Event.event_id(event)})
      :ok
    end
  end

  test "Dispatcher.async/3 dispatches a retried event only once" do
    Process.register(self(), :dedup_sink)
    event_id = id()

    event = %Event{
      type: "message",
      payload: %{},
      raw: %{"payload" => %{"event_id" => event_id}},
      transport: :socket_mode
    }

    context = %Context{transport: :socket_mode, bot_token: nil}

    # First delivery runs; the retry (same event_id) is dropped.
    Dispatcher.async(OnceBot, event, context)
    Dispatcher.async(OnceBot, event, context)

    assert_receive {:handled, "message", ^event_id}, 1_000
    refute_receive {:handled, "message", ^event_id}, 100
  end
end
