defmodule Slink.APITest do
  use ExUnit.Case, async: false

  alias Slink.API

  setup do
    {:ok, base_url, pid} = Slink.Test.FakeWebApi.start()
    Application.put_env(:slink, :api_base_url, base_url)

    on_exit(fn ->
      Application.delete_env(:slink, :api_base_url)
      Process.exit(pid, :normal)
    end)

    :ok
  end

  test "open_connection/1 returns the WebSocket URL" do
    assert {:ok, "wss://example/link"} = API.open_connection("xapp-test")
  end

  test "post_message returns the decoded body on success" do
    assert {:ok, %{"ok" => true, "channel" => "C1"}} = API.post_message("xoxb-test", "C1", "hi")

    assert {:ok, %{"ok" => true}} =
             API.post_message("xoxb-test", "C1", "hello", %{thread_ts: "1.0"})
  end

  test "add_reaction/4 and remove_reaction/4 succeed" do
    assert {:ok, %{"ok" => true}} = API.add_reaction("xoxb-test", "C1", "1.0", "eyes")
    assert {:ok, %{"ok" => true}} = API.remove_reaction("xoxb-test", "C1", "1.0", "eyes")
  end

  test "call/3 surfaces Slack's logical error as {:error, reason}" do
    assert {:error, "not_authed"} = API.call("xoxb-test", "boom.method", %{})
  end

  test "call/3 flags a response missing the ok field" do
    assert {:error, {:http, 200, %{"unexpected" => true}}} =
             API.call("xoxb-test", "weird.method", %{})
  end

  test "call/3 returns a transport error when the host is unreachable" do
    Application.put_env(:slink, :api_base_url, "http://127.0.0.1:1")
    assert {:error, _reason} = API.call("xoxb-test", "chat.postMessage", %{})
  end

  test "open_connection/1 propagates errors" do
    Application.put_env(:slink, :api_base_url, "http://127.0.0.1:1")
    assert {:error, _reason} = API.open_connection("xapp-test")
  end
end
