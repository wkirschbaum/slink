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

  test "update_message/5 and delete_message/3 succeed" do
    assert {:ok, %{"ok" => true}} = API.update_message("xoxb", "C1", "1.2", "edited")
    assert {:ok, %{"ok" => true}} = API.delete_message("xoxb", "C1", "1.2")
  end

  test "post_ephemeral/5 succeeds" do
    assert {:ok, %{"ok" => true}} = API.post_ephemeral("xoxb", "C1", "U1", "just for you")
  end

  test "get_permalink/3 returns the permalink URL" do
    assert {:ok, "https://slack/p1"} = API.get_permalink("xoxb", "C1", "1.2")
  end

  test "user_info/2 returns the user profile" do
    assert {:ok, %{"user" => %{"name" => "alice"}}} = API.user_info("xoxb", "U1")
  end

  test "views open/update/push/publish succeed" do
    assert {:ok, %{"view" => %{"id" => "V1"}}} = API.open_view("xoxb", "trigger", %{})
    assert {:ok, %{"view" => %{"id" => "V1"}}} = API.update_view("xoxb", "V1", %{})
    assert {:ok, %{"view" => %{"id" => "V2"}}} = API.push_view("xoxb", "trigger", %{})
    assert {:ok, %{"ok" => true}} = API.publish_view("xoxb", "U1", %{})
  end

  test "open_dm/2 returns the DM channel id" do
    assert {:ok, "D1"} = API.open_dm("xoxb", "U1")
  end

  test "join_channel/2, history/3, schedule_message/5 and auth_test/1 succeed" do
    assert {:ok, %{"channel" => %{"id" => "C1"}}} = API.join_channel("xoxb", "C1")
    assert {:ok, %{"messages" => []}} = API.history("xoxb", "C1", %{limit: 5})

    assert {:ok, %{"scheduled_message_id" => "Q1"}} =
             API.schedule_message("xoxb", "C1", 1_700_000_000, "later")

    assert {:ok, %{"user_id" => "U-BOT"}} = API.auth_test("xoxb")
  end

  test "upload_file/3 runs the three-step external flow end to end" do
    Application.put_env(:slink, :test_api_sink, self())
    on_exit(fn -> Application.delete_env(:slink, :test_api_sink) end)

    assert {:ok, %{"files" => [%{"id" => "F1"}]}} =
             API.upload_file("xoxb", "col1,col2\n1,2\n",
               filename: "report.csv",
               channel: "C1",
               initial_comment: "this week's numbers"
             )

    # getUploadURLExternal is form-encoded (the method rejects JSON) and
    # carries the exact byte length.
    assert_receive {:api_request, "/files.getUploadURLExternal", params}, 1_000
    assert params == %{"filename" => "report.csv", "length" => "14"}

    assert_receive {:api_request, "/upload/bytes", "col1,col2\n1,2\n"}, 1_000

    assert_receive {:api_request, "/files.completeUploadExternal",
                    %{
                      "files" => [%{"id" => "F1"}],
                      "channel_id" => "C1",
                      "initial_comment" => "this week's numbers"
                    }},
                   1_000
  end

  test "upload_file/3 surfaces a failure to get the upload URL" do
    Application.put_env(:slink, :api_base_url, "http://127.0.0.1:1")
    assert {:error, _reason} = API.upload_file("xoxb", "bytes", filename: "x.txt")
  end

  describe "stream/3" do
    setup do
      on_exit(fn -> Application.delete_env(:slink, :api_caller) end)
      :ok
    end

    defp script_pages(test_pid) do
      Application.put_env(:slink, :api_caller, fn _token, "conversations.history", params ->
        send(test_pid, {:page_fetched, params[:cursor]})

        case params[:cursor] do
          nil ->
            {:ok,
             %{
               "ok" => true,
               "messages" => [1, 2],
               "response_metadata" => %{"next_cursor" => "c2"}
             }}

          "c2" ->
            {:ok,
             %{"ok" => true, "messages" => [3], "response_metadata" => %{"next_cursor" => ""}}}
        end
      end)
    end

    test "follows next_cursor to the end" do
      script_pages(self())

      messages =
        API.stream("xoxb", "conversations.history", %{channel: "C1"})
        |> Enum.flat_map(& &1["messages"])

      assert messages == [1, 2, 3]
    end

    test "is lazy: fetches only the pages the consumer demands" do
      script_pages(self())

      [page] = API.stream("xoxb", "conversations.history", %{channel: "C1"}) |> Enum.take(1)
      assert page["messages"] == [1, 2]

      assert_receive {:page_fetched, nil}
      refute_receive {:page_fetched, "c2"}, 100
    end

    test "defaults limit to 200 without clobbering an explicit one" do
      test_pid = self()

      Application.put_env(:slink, :api_caller, fn _token, _method, params ->
        send(test_pid, {:limit, params[:limit]})
        {:ok, %{"ok" => true}}
      end)

      API.stream("xoxb", "users.list") |> Enum.to_list()
      assert_receive {:limit, 200}

      API.stream("xoxb", "users.list", %{limit: 5}) |> Enum.to_list()
      assert_receive {:limit, 5}
    end

    test "a failing page raises Slink.API.Error" do
      Application.put_env(:slink, :api_caller, fn _token, _method, _params ->
        {:error, "invalid_cursor"}
      end)

      assert_raise Slink.API.Error, ~r/invalid_cursor/, fn ->
        API.stream("xoxb", "conversations.history", %{channel: "C1"}) |> Enum.to_list()
      end
    end
  end

  test "respond/2 posts to a response_url" do
    base = Application.get_env(:slink, :api_base_url)
    assert {:ok, _} = API.respond("#{base}/response", %{text: "hi", response_type: "ephemeral"})
  end

  test "call/3 retries a 429 and gives up with the last response after max_retries" do
    # `rate.limited` always answers 429 (Retry-After: 0). Proves the retry path
    # runs and, once exhausted, surfaces the final response rather than looping.
    assert {:error, {:http, 429, _body}} = API.call("xoxb", "rate.limited", %{})
  end
end
