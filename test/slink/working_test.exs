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

  test "brackets fun with reactions.add then reactions.remove, returning fun's value" do
    assert :done = Slink.working(context(%{"channel" => "C1", "ts" => "1.0"}), fn -> :done end)

    assert_receive {:api_request, "/reactions.add",
                    %{"channel" => "C1", "timestamp" => "1.0", "name" => "hourglass_flowing_sand"}}

    assert_receive {:api_request, "/reactions.remove",
                    %{"channel" => "C1", "timestamp" => "1.0", "name" => "hourglass_flowing_sand"}}
  end

  test "honors a custom :emoji" do
    Slink.working(context(%{"channel" => "C1", "ts" => "1.0"}), fn -> :ok end, emoji: "eyes")
    assert_receive {:api_request, "/reactions.add", %{"name" => "eyes"}}
    assert_receive {:api_request, "/reactions.remove", %{"name" => "eyes"}}
  end

  test "removes the reaction even if fun raises" do
    ctx = context(%{"channel" => "C1", "ts" => "1.0"})
    assert_raise RuntimeError, "boom", fn -> Slink.working(ctx, fn -> raise "boom" end) end
    assert_receive {:api_request, "/reactions.add", _}
    assert_receive {:api_request, "/reactions.remove", _}
  end

  test "skips the reaction when the event has no message timestamp; still runs fun" do
    assert :ran = Slink.working(context(%{"channel" => "C1"}), fn -> :ran end)
    refute_receive {:api_request, "/reactions.add", _}, 200
  end
end
