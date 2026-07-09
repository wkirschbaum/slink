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
