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
    {:ok, %{channel: channel, queue: [], busy: false}, idle_stop()}
  end

  @impl true
  def handle_cast({:enqueue, request}, state) do
    {:noreply, pump(%{state | queue: bounded(state.queue ++ [request], state.channel)}),
     idle_stop()}
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
    {:noreply, pump(%{state | busy: false}), idle_stop()}
  end

  # GenServer idle timeout: no message for idle_stop() ms. Stop when nothing is
  # queued or in flight, so a bot that has posted to many channels doesn't keep
  # one idle worker per channel forever; `restart: :transient` means a normal
  # stop isn't restarted, and the next send just starts a fresh worker. (A cast
  # racing the stop can be lost — acceptable for a fire-and-forget queue, and
  # the window is microseconds once per idle period.)
  def handle_info(:timeout, %{queue: [], busy: false} = state), do: {:stop, :normal, state}
  def handle_info(:timeout, state), do: {:noreply, state, idle_stop()}

  # Send the head of the queue, then hold off `interval` before the next one.
  # Scheduling the next drain only after the call returns keeps us at or below
  # the rate even when a call is slow — never above it.
  defp pump(%{busy: true} = state), do: state
  defp pump(%{queue: []} = state), do: state

  defp pump(%{queue: [{bot_token, method, params} | rest]} = state) do
    try do
      case send_fun().(bot_token, method, params) do
        {:error, reason} ->
          Logger.warning("Slink.Rate: #{method} on #{state.channel} failed: #{inspect(reason)}")

        _ok ->
          :ok
      end
    rescue
      # A bad body (e.g. one Req can't JSON-encode) must not crash the worker and
      # drop the whole queue — log it and move on to the next request.
      e ->
        Logger.warning("Slink.Rate: #{method} on #{state.channel} raised: #{inspect(e)}")
    end

    Process.send_after(self(), :drain, interval())
    %{state | queue: rest, busy: true}
  end

  @default_interval to_timeout(second: 1)
  @default_idle_stop to_timeout(minute: 10)

  defp interval, do: Application.get_env(:slink, :rate_interval_ms, @default_interval)
  defp max_queue, do: Application.get_env(:slink, :rate_max_queue, 1_000)
  defp idle_stop, do: Application.get_env(:slink, :rate_idle_stop_ms, @default_idle_stop)
  defp send_fun, do: Application.get_env(:slink, :rate_sender, &Slink.API.call/3)
end
