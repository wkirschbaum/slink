defmodule Slink.Identity do
  @moduledoc """
  Caches the bot's own identity (`auth.test`) per token.

  This is what fills `Slink.Context`'s `:bot_user_id`: the transports prewarm
  the cache (Socket Mode on connect, the Events API plug per request) and stamp
  the cached id into the handler context, powering `Slink.mentions_me?/1`.

  Reads never block and never touch the network — until the one-off `auth.test`
  round-trip completes, `bot_user_id/1` is `nil`. A failed fetch stays uncached,
  so the next prewarm simply retries.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The cached bot user id for `token`, or `nil` if not (yet) known."
  def bot_user_id(token) when is_binary(token) do
    with tab when tab != :undefined <- :ets.whereis(@table),
         [{_key, user_id}] <- :ets.lookup(@table, key(token)) do
      user_id
    else
      _ -> nil
    end
  end

  def bot_user_id(_token), do: nil

  @doc """
  Fetch and cache the identity for `token` off-process, unless already cached.

  Fire-and-forget: the `auth.test` call runs under `Slink.TaskSupervisor`, so a
  slow or failing Slack never blocks the caller (a transport). Safe to call on
  every event — a cache hit is a single ETS read.
  """
  def prewarm(token) when is_binary(token) do
    if :ets.whereis(@table) != :undefined and :ets.lookup(@table, key(token)) == [] do
      Task.Supervisor.start_child(Slink.TaskSupervisor, fn ->
        case fetch_fun().(token) do
          {:ok, %{"user_id" => user_id}} when is_binary(user_id) ->
            :ets.insert(@table, {key(token), user_id})

          _error ->
            # Transient failure: stay unknown; the next prewarm retries.
            :ok
        end
      end)
    end

    :ok
  end

  def prewarm(_token), do: :ok

  # Tokens are secrets — key the cache on a hash so they never sit in the table
  # (which debugging tools like :ets.tab2list or observer would print).
  defp key(token), do: :crypto.hash(:sha256, token)

  # Test seam (like :rate_sender): lets tests answer auth.test without a network.
  defp fetch_fun, do: Application.get_env(:slink, :identity_fetch, &Slink.API.auth_test/1)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
