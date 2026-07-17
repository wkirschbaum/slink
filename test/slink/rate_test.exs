defmodule Slink.RateTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    test_pid = self()
    Application.put_env(:slink, :rate_interval_ms, 30)

    Application.put_env(:slink, :rate_sender, fn token, method, params ->
      send(test_pid, {:sent, token, method, params})
      {:ok, %{"ok" => true}}
    end)

    on_exit(fn ->
      Application.delete_env(:slink, :rate_interval_ms)
      Application.delete_env(:slink, :rate_sender)
    end)

    :ok
  end

  test "delivers a channel's messages in FIFO order" do
    for text <- ~w(one two three), do: Slink.Rate.post_message("xoxb", "C-order", text)

    assert_receive {:sent, "xoxb", "chat.postMessage", %{channel: "C-order", text: "one"}}, 1_000
    assert_receive {:sent, "xoxb", "chat.postMessage", %{text: "two"}}, 1_000
    assert_receive {:sent, "xoxb", "chat.postMessage", %{text: "three"}}, 1_000
  end

  test "spaces out sends on a channel by at least the configured interval" do
    Slink.Rate.post_message("xoxb", "C-space", "a")
    Slink.Rate.post_message("xoxb", "C-space", "b")

    assert_receive {:sent, _, _, %{text: "a"}}, 1_000
    t1 = System.monotonic_time(:millisecond)
    assert_receive {:sent, _, _, %{text: "b"}}, 1_000
    t2 = System.monotonic_time(:millisecond)

    # Second send waits ~interval (30ms). Allow slack for scheduler jitter.
    assert t2 - t1 >= 20
  end

  test "different channels drain concurrently" do
    Slink.Rate.post_message("xoxb", "C-a", "hi-a")
    Slink.Rate.post_message("xoxb", "C-b", "hi-b")

    assert_receive {:sent, _, _, %{channel: "C-a"}}, 1_000
    assert_receive {:sent, _, _, %{channel: "C-b"}}, 1_000
  end

  test "logs and keeps draining when a send fails" do
    Application.put_env(:slink, :rate_sender, fn _t, _m, _p -> {:error, :ratelimited} end)
    # Should not crash the worker; just returns :ok to the caller.
    assert Slink.Rate.post_message("xoxb", "C-fail", "x") == :ok
  end

  test "a raising send (e.g. a non-encodable body) doesn't crash the worker or drop the queue" do
    test_pid = self()

    # First send raises (as Req would on a body it can't encode); the rest must
    # still drain on the same worker — a bad payload can't take the channel down.
    Application.put_env(:slink, :rate_sender, fn _t, _m, params ->
      if params.text == "boom", do: raise("cannot encode")
      send(test_pid, {:sent, params.text})
      {:ok, %{"ok" => true}}
    end)

    log =
      capture_log(fn ->
        Slink.Rate.post_message("xoxb", "C-raise", "boom")
        Slink.Rate.post_message("xoxb", "C-raise", "after")

        assert_receive {:sent, "after"}, 1_000
      end)

    [{pid, _}] = Registry.lookup(Slink.Rate.Registry, "C-raise")
    assert Process.alive?(pid)
    assert log =~ "cannot encode"
  end

  test "an exiting send (e.g. a pool-checkout timeout) doesn't crash the worker either" do
    test_pid = self()

    # A slow Slack surfaces as a Finch pool-checkout timeout, which *exits*
    # rather than raises — the worker must survive that too and keep draining.
    Application.put_env(:slink, :rate_sender, fn _t, _m, params ->
      if params.text == "boom", do: exit({:timeout, {NimblePool, :checkout, [:pool]}})
      send(test_pid, {:sent, params.text})
      {:ok, %{"ok" => true}}
    end)

    log =
      capture_log(fn ->
        Slink.Rate.post_message("xoxb", "C-exit", "boom")
        Slink.Rate.post_message("xoxb", "C-exit", "after")

        assert_receive {:sent, "after"}, 1_000
      end)

    [{pid, _}] = Registry.lookup(Slink.Rate.Registry, "C-exit")
    assert Process.alive?(pid)
    assert log =~ "exited"
  end

  test "an idle channel worker stops itself; the next send starts a fresh one" do
    Application.put_env(:slink, :rate_idle_stop_ms, 60)
    on_exit(fn -> Application.delete_env(:slink, :rate_idle_stop_ms) end)

    Slink.Rate.post_message("xoxb", "C-idle", "first")
    assert_receive {:sent, _, _, %{text: "first"}}, 1_000

    [{pid, _}] = Registry.lookup(Slink.Rate.Registry, "C-idle")
    ref = Process.monitor(pid)

    # Nothing queued or in flight → the worker exits normally after the idle
    # period, and transient restart leaves it stopped.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    # Registry cleanup is asynchronous; wait for the name to actually clear so
    # the next enqueue can't cast into the dead pid.
    wait_until(fn -> Registry.lookup(Slink.Rate.Registry, "C-idle") == [] end)

    Slink.Rate.post_message("xoxb", "C-idle", "second")
    assert_receive {:sent, _, _, %{text: "second"}}, 1_000
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  test "crash-report formatting redacts bot tokens from queued requests" do
    # Freeze draining so a request actually sits in the queue with its token.
    Application.put_env(:slink, :rate_interval_ms, 60_000)

    Slink.Rate.post_message("xoxb-queue-secret", "C-redact", "one")
    Slink.Rate.post_message("xoxb-queue-secret", "C-redact", "two")

    [{pid, _}] = Registry.lookup(Slink.Rate.Registry, "C-redact")

    # :sys.get_status renders the state the way a crash report would.
    formatted = inspect(:sys.get_status(pid), limit: :infinity)
    refute formatted =~ "xoxb-queue-secret"
    assert formatted =~ "[REDACTED]"

    # The real queue still holds the actual token for sending.
    assert [{"xoxb-queue-secret", _, _}] = :sys.get_state(pid).queue
  end

  test "format_status also redacts the token from the last handled message" do
    # OTP includes the last message in a crash report; an enqueue cast carries
    # the token, so it must be redacted alongside the state.
    status = %{
      state: %{channel: "C1", queue: [], busy: false},
      message: {:enqueue, {"xoxb-msg-secret", "chat.postMessage", %{text: "hi"}}}
    }

    formatted = Slink.Rate.Channel.format_status(status)

    refute inspect(formatted, limit: :infinity) =~ "xoxb-msg-secret"
    assert {:enqueue, {"[REDACTED]", "chat.postMessage", %{text: "hi"}}} = formatted.message
  end

  test "bounds the queue under sustained backpressure, dropping oldest" do
    Application.put_env(:slink, :rate_max_queue, 3)
    # Freeze draining after the first send so the queue actually builds up.
    Application.put_env(:slink, :rate_interval_ms, 60_000)

    log =
      capture_log(fn ->
        for i <- 1..10, do: Slink.Rate.enqueue("xoxb", "C-bound", "chat.postMessage", %{n: i})
        Process.sleep(50)
      end)

    [{pid, _}] = Registry.lookup(Slink.Rate.Registry, "C-bound")
    assert length(:sys.get_state(pid).queue) <= 3
    assert log =~ "dropping"
  end
end
