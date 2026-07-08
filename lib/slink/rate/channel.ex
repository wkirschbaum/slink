defmodule Slink.Rate.Channel do
  @moduledoc """
  A single channel's outbound queue. Drains one request, then waits the
  configured interval before the next — so a channel never exceeds Slack's
  ~1 msg/sec limit. One of these runs per channel under `Slink.Rate.Supervisor`.
  """

  use GenServer, restart: :transient
  require Logger

  def start_link(channel) do
    GenServer.start_link(__MODULE__, channel, name: via(channel))
  end

  defp via(channel), do: {:via, Registry, {Slink.Rate.Registry, channel}}

  @impl true
  def init(channel) do
    {:ok, %{channel: channel, queue: [], busy: false}}
  end

  @impl true
  def handle_cast({:enqueue, request}, state) do
    {:noreply, pump(%{state | queue: bounded(state.queue ++ [request], state.channel)})}
  end

  # Never let a stalled channel (e.g. Slack down) grow the queue without bound.
  # Past the cap we drop the oldest messages — the freshest are most useful.
  defp bounded(queue, channel) do
    max = max_queue()

    case length(queue) - max do
      overflow when overflow > 0 ->
        Logger.warning("Slink.Rate: #{channel} queue over #{max}, dropping #{overflow} oldest")
        Enum.drop(queue, overflow)

      _ ->
        queue
    end
  end

  @impl true
  def handle_info(:drain, state) do
    {:noreply, pump(%{state | busy: false})}
  end

  # Send the head of the queue, then hold off `interval` before the next one.
  # Scheduling the next drain only after the call returns keeps us at or below
  # the rate even when a call is slow — never above it.
  defp pump(%{busy: true} = state), do: state
  defp pump(%{queue: []} = state), do: state

  defp pump(%{queue: [{bot_token, method, params} | rest]} = state) do
    case send_fun().(bot_token, method, params) do
      {:error, reason} ->
        Logger.warning("Slink.Rate: #{method} on #{state.channel} failed: #{inspect(reason)}")

      _ok ->
        :ok
    end

    Process.send_after(self(), :drain, interval())
    %{state | queue: rest, busy: true}
  end

  defp interval, do: Application.get_env(:slink, :rate_interval_ms, 1_000)
  defp max_queue, do: Application.get_env(:slink, :rate_max_queue, 1_000)
  defp send_fun, do: Application.get_env(:slink, :rate_sender, &Slink.API.call/3)
end
