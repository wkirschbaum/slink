defmodule Slink.WorkingTest do
  use ExUnit.Case, async: false

  alias Slink.{Context, Event}

  setup do
    {:ok, base_url, pid} = Slink.Test.FakeWebApi.start()
    Application.put_env(:slink, :api_base_url, base_url)
    Application.put_env(:slink, :test_api_sink, self())

    on_exit(fn ->
      Application.delete_env(:slink, :api_base_url)
      Application.delete_env(:slink, :test_api_sink)
      Process.exit(pid, :normal)
    end)

    :ok
  end

  defp context(payload) do
    %Context{
      transport: :socket_mode,
      bot_token: "xoxb",
      event: %Event{type: :app_mention, payload: payload, raw: %{}, transport: :socket_mode}
    }
  end

  # A fun that reports its pid and blocks until released — so the "slow" path is
  # deterministic (it definitely outlives delay_ms: 0) without Process.sleep.
  defp blocking_fun(test_pid, on_release) do
    fn ->
      send(test_pid, {:running, self()})

      receive do
        :release -> on_release.()
      end
    end
  end

  test "does not show the indicator when the work finishes within the delay" do
    ctx = context(%{"channel" => "C1", "ts" => "1.0"})
    assert :quick = Slink.working(ctx, fn -> :quick end, delay_ms: 5_000)
    refute_receive {:api_request, "/reactions.add", _}, 200
  end

  test "shows the indicator once the work exceeds the delay, then clears it" do
    ctx = context(%{"channel" => "C1", "ts" => "1.0"})
    fun = blocking_fun(self(), fn -> :done end)
    caller = Task.async(fn -> Slink.working(ctx, fun, delay_ms: 0) end)

    assert_receive {:running, fun_pid}, 1_000

    assert_receive {:api_request, "/reactions.add",
                    %{"channel" => "C1", "timestamp" => "1.0", "name" => "hourglass_flowing_sand"}},
                   1_000

    send(fun_pid, :release)
    assert :done = Task.await(caller)
    assert_receive {:api_request, "/reactions.remove", %{"channel" => "C1"}}, 1_000
  end

  test "honors a custom :emoji" do
    ctx = context(%{"channel" => "C1", "ts" => "1.0"})
    fun = blocking_fun(self(), fn -> :ok end)
    caller = Task.async(fn -> Slink.working(ctx, fun, delay_ms: 0, emoji: "eyes") end)

    assert_receive {:running, fun_pid}, 1_000
    assert_receive {:api_request, "/reactions.add", %{"name" => "eyes"}}, 1_000
    send(fun_pid, :release)
    Task.await(caller)
    assert_receive {:api_request, "/reactions.remove", %{"name" => "eyes"}}, 1_000
  end

  test "removes the indicator even if the work raises" do
    ctx = context(%{"channel" => "C1", "ts" => "1.0"})
    fun = blocking_fun(self(), fn -> raise "boom" end)
    caller = Task.async(fn -> catch_exit(Slink.working(ctx, fun, delay_ms: 0)) end)

    assert_receive {:running, fun_pid}, 1_000
    assert_receive {:api_request, "/reactions.add", _}, 1_000
    send(fun_pid, :release)

    assert {%RuntimeError{message: "boom"}, _stack} = Task.await(caller)
    assert_receive {:api_request, "/reactions.remove", _}, 1_000
  end

  test "runs fun inline and shows nothing when the event has no message ts" do
    assert :ran = Slink.working(context(%{"channel" => "C1"}), fn -> :ran end)
    refute_receive {:api_request, "/reactions.add", _}, 200
  end
end
