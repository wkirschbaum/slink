defmodule Slink.Dedup do
  @moduledoc """
  Drops Slack's *retried* event deliveries so a handler never fires twice.

  Slack re-sends an event (same `event_id`) when it doesn't see a timely ACK —
  even though both transports ACK before the handler runs, a slow network or a
  restart can still produce duplicates. This keeps a short-lived set of seen
  keys (`{handler_module, event_id}`) in ETS; the dispatcher consults it
  before dispatching.

  It's a `set` ETS table owned by this process but read/written directly by
  callers (so the dedup check never blocks on a GenServer). A periodic sweep
  evicts entries past their TTL.

  The table is node-local, so dedup is per-instance. Across a multi-node fleet
  a retry can land on a different instance than the original delivery (Slack
  load-balances Socket Mode connections, and an HTTP retry can hit a different
  pod), and that instance won't recognise it. Retries are rare — both
  transports ACK before the handler runs — so this is a best-effort safety net;
  hard cross-instance dedup would need a shared store.

  ## Configuration

    * `config :slink, :dedup, true` — master switch (default `true`). When
      `false`, `seen?/1` always returns `false` and nothing is tracked.
    * `config :slink, :dedup_ttl_ms, 660_000` — how long a key is remembered
      (default 11 minutes). Slack retries a failed delivery immediately, after
      ~1 minute, and after ~5 minutes, so the default covers the whole schedule
      with margin.
  """

  use GenServer

  @table __MODULE__
  # Slack's last retry lands ~6 minutes after the original delivery; remember
  # keys for 11 minutes so every retry in the schedule is still recognised.
  @default_ttl_ms to_timeout(minute: 11)
  @sweep_ms to_timeout(second: 30)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Whether `key` has been seen within the TTL; records it if not.

  Returns `false` (and remembers `key`) the first time, `true` on a repeat.
  Always `false` when dedup is disabled or the table isn't up yet, so a missing
  dedup process fails open — never silently swallowing real events.
  """
  def seen?(key) do
    # Event ids are unique per event, so a key we've stored can only be a retry —
    # `insert_new` returning false *is* the "seen before" answer. The stored
    # expiry is read only by the sweep, which is all the TTL is for (bounding
    # memory); a genuine retry after the TTL is vanishingly unlikely.
    if enabled?() and :ets.whereis(@table) != :undefined do
      not :ets.insert_new(@table, {key, System.monotonic_time(:millisecond) + ttl()})
    else
      false
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    # Delete every entry whose expiry is at or before now.
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)

  defp enabled?, do: Application.get_env(:slink, :dedup, true)
  defp ttl, do: Application.get_env(:slink, :dedup_ttl_ms, @default_ttl_ms)
end
