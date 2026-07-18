defmodule Slink.Playground.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Slink.Playground.Workspace

  setup context do
    name = :"playground_ws_#{context.test}"
    start_supervised!({Workspace, name: name, module: NoBot, bot_token: "xoxb-playground"})
    :ok = Workspace.set_base_url(name, "http://127.0.0.1:4040")
    %{ws: name}
  end

  defp api(ws, method, params), do: Workspace.api_call(ws, method, params)

  defp messages(ws, channel), do: Workspace.snapshot(ws)["messages"][channel]

  test "auth.test identifies the playground bot", %{ws: ws} do
    assert %{"ok" => true, "user_id" => "U0BOT", "bot_id" => "B0BOT", "team_id" => "T0PLAY"} =
             api(ws, "auth.test", %{})
  end

  test "chat.postMessage appends a bot message with a monotonic Slack-shaped ts", %{ws: ws} do
    %{"ok" => true, "ts" => ts1} =
      api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "one"})

    %{"ok" => true, "ts" => ts2} =
      api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "two"})

    assert ts1 =~ ~r/^\d{10}\.\d{6}$/
    assert ts2 > ts1

    assert [%{"text" => "one", "user" => "U0BOT", "bot_id" => "B0BOT"}, %{"text" => "two"}] =
             messages(ws, "C0GENERAL")
  end

  test "posting to an unknown channel is channel_not_found", %{ws: ws} do
    assert %{"ok" => false, "error" => "channel_not_found"} =
             api(ws, "chat.postMessage", %{"channel" => "C0NOPE", "text" => "hi"})
  end

  test "a thread reply bumps the root's reply_count", %{ws: ws} do
    %{"ts" => root} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "root"})

    api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "r1", "thread_ts" => root})
    api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "r2", "thread_ts" => root})

    assert [%{"ts" => ^root, "reply_count" => 2}, %{"thread_ts" => ^root}, _] =
             messages(ws, "C0GENERAL")
  end

  test "chat.update edits text and blocks; wrong ts is message_not_found", %{ws: ws} do
    %{"ts" => ts} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "before"})

    assert %{"ok" => true} =
             api(ws, "chat.update", %{
               "channel" => "C0GENERAL",
               "ts" => ts,
               "text" => "after",
               "blocks" => [%{"type" => "divider"}]
             })

    assert [%{"text" => "after", "blocks" => [%{"type" => "divider"}]}] =
             messages(ws, "C0GENERAL")

    assert %{"error" => "message_not_found"} =
             api(ws, "chat.update", %{"channel" => "C0GENERAL", "ts" => "0.0", "text" => "x"})

    assert %{"error" => "channel_not_found"} =
             api(ws, "chat.update", %{"channel" => "C0NOPE", "ts" => ts, "text" => "x"})
  end

  test "chat.delete removes the message and its thread replies", %{ws: ws} do
    %{"ts" => root} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "root"})
    api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "r", "thread_ts" => root})
    %{"ts" => other} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "keep"})

    assert %{"ok" => true} = api(ws, "chat.delete", %{"channel" => "C0GENERAL", "ts" => root})
    assert [%{"ts" => ^other}] = messages(ws, "C0GENERAL")
  end

  test "chat.postEphemeral flags the message; unknown user errors", %{ws: ws} do
    assert %{"ok" => true, "message_ts" => _} =
             api(ws, "chat.postEphemeral", %{
               "channel" => "C0GENERAL",
               "user" => "U0DEV",
               "text" => "psst"
             })

    assert [%{"ephemeral" => true, "text" => "psst"}] = messages(ws, "C0GENERAL")

    assert %{"error" => "user_not_found"} =
             api(ws, "chat.postEphemeral", %{
               "channel" => "C0GENERAL",
               "user" => "U9",
               "text" => "x"
             })
  end

  test "bot reactions add and remove, with Slack's error shapes", %{ws: ws} do
    %{"ts" => ts} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "hi"})
    add = %{"channel" => "C0GENERAL", "timestamp" => ts, "name" => "eyes"}

    assert %{"ok" => true} = api(ws, "reactions.add", add)
    assert %{"error" => "already_reacted"} = api(ws, "reactions.add", add)

    assert [%{"reactions" => [%{"name" => "eyes", "users" => ["U0BOT"], "count" => 1}]}] =
             messages(ws, "C0GENERAL")

    assert %{"ok" => true} = api(ws, "reactions.remove", add)
    assert %{"error" => "no_reaction"} = api(ws, "reactions.remove", add)
    assert [msg] = messages(ws, "C0GENERAL")
    refute Map.has_key?(msg, "reactions")

    assert %{"error" => "message_not_found"} =
             api(ws, "reactions.add", %{add | "timestamp" => "0.0"})
  end

  test "the human and the bot can share a reaction", %{ws: ws} do
    %{"ts" => ts} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "hi"})
    :ok = Workspace.user_reaction(ws, "add", "C0GENERAL", ts, "eyes")
    api(ws, "reactions.add", %{"channel" => "C0GENERAL", "timestamp" => ts, "name" => "eyes"})

    assert [%{"reactions" => [%{"name" => "eyes", "users" => ["U0DEV", "U0BOT"], "count" => 2}]}] =
             messages(ws, "C0GENERAL")
  end

  test "conversations.history returns top-level messages newest first", %{ws: ws} do
    %{"ts" => root} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "one"})

    api(ws, "chat.postMessage", %{
      "channel" => "C0GENERAL",
      "text" => "reply",
      "thread_ts" => root
    })

    api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "two"})

    assert %{"ok" => true, "messages" => [%{"text" => "two"}, %{"text" => "one"}]} =
             api(ws, "conversations.history", %{"channel" => "C0GENERAL"})
  end

  test "conversations.replies returns the thread oldest first", %{ws: ws} do
    %{"ts" => root} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "root"})

    api(ws, "chat.postMessage", %{
      "channel" => "C0GENERAL",
      "text" => "reply",
      "thread_ts" => root
    })

    assert %{"ok" => true, "messages" => [%{"text" => "root"}, %{"text" => "reply"}]} =
             api(ws, "conversations.replies", %{"channel" => "C0GENERAL", "ts" => root})

    assert %{"error" => "thread_not_found"} =
             api(ws, "conversations.replies", %{"channel" => "C0GENERAL", "ts" => "0.0"})
  end

  test "views.open/push/update manage the modal stack", %{ws: ws} do
    %{"ok" => true, "view" => %{"id" => v1}} =
      api(ws, "views.open", %{
        "trigger_id" => "t",
        "view" => %{"type" => "modal", "callback_id" => "a"}
      })

    %{"view" => %{"id" => v2}} =
      api(ws, "views.push", %{
        "trigger_id" => "t",
        "view" => %{"type" => "modal", "callback_id" => "b"}
      })

    assert v1 != v2
    assert %{"views" => %{"stack" => [%{"id" => ^v1}, %{"id" => ^v2}]}} = Workspace.snapshot(ws)

    %{"ok" => true, "view" => %{"id" => ^v1, "callback_id" => "a2"}} =
      api(ws, "views.update", %{
        "view_id" => v1,
        "view" => %{"type" => "modal", "callback_id" => "a2"}
      })

    assert %{"error" => "not_found"} =
             api(ws, "views.update", %{"view_id" => "V9999", "view" => %{"type" => "modal"}})
  end

  test "views.publish sets the Home tab", %{ws: ws} do
    api(ws, "views.publish", %{
      "user_id" => "U0DEV",
      "view" => %{"type" => "home", "blocks" => []}
    })

    assert %{"views" => %{"home" => %{"id" => "VHOME", "type" => "home"}}} =
             Workspace.snapshot(ws)
  end

  test "apply_ack drives the modal stack like Slack's response_action", %{ws: ws} do
    %{"view" => %{"id" => v1}} =
      api(ws, "views.open", %{"trigger_id" => "t", "view" => %{"type" => "modal"}})

    # errors: nothing changes
    :ok =
      Workspace.apply_ack(ws, v1, %{"response_action" => "errors", "errors" => %{"b" => "bad"}})

    assert %{"views" => %{"stack" => [_]}} = Workspace.snapshot(ws)

    # update: view replaced, id kept (atom-keyed views from handlers are normalised)
    :ok =
      Workspace.apply_ack(ws, v1, %{
        response_action: "update",
        view: %{type: "modal", callback_id: "next"}
      })

    assert %{"views" => %{"stack" => [%{"id" => ^v1, "callback_id" => "next"}]}} =
             Workspace.snapshot(ws)

    # push: second view on the stack
    :ok =
      Workspace.apply_ack(ws, v1, %{"response_action" => "push", "view" => %{"type" => "modal"}})

    assert %{"views" => %{"stack" => [_, _]}} = Workspace.snapshot(ws)

    # close (empty ack): the submitted view goes away
    :ok = Workspace.apply_ack(ws, v1, %{})
    assert %{"views" => %{"stack" => [%{"id" => v2}]}} = Workspace.snapshot(ws)

    # clear: everything goes away
    :ok = Workspace.apply_ack(ws, v2, %{"response_action" => "clear"})
    assert %{"views" => %{"stack" => []}} = Workspace.snapshot(ws)
  end

  test "streaming accumulates markdown across append and stop", %{ws: ws} do
    %{"ts" => root} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "q"})

    %{"ok" => true, "ts" => ts} =
      api(ws, "chat.startStream", %{"channel" => "C0GENERAL", "thread_ts" => root})

    assert {:ok, %{"streaming" => true}} = Workspace.fetch_message(ws, "C0GENERAL", ts)

    api(ws, "chat.appendStream", %{"channel" => "C0GENERAL", "ts" => ts, "markdown_text" => "hel"})

    api(ws, "chat.appendStream", %{"channel" => "C0GENERAL", "ts" => ts, "markdown_text" => "lo "})

    api(ws, "chat.stopStream", %{"channel" => "C0GENERAL", "ts" => ts, "markdown_text" => "world"})

    assert {:ok, %{"text" => "hello world", "thread_ts" => ^root} = msg} =
             Workspace.fetch_message(ws, "C0GENERAL", ts)

    refute Map.has_key?(msg, "streaming")
  end

  test "chat.startStream without a thread is invalid_arguments", %{ws: ws} do
    assert %{"error" => "invalid_arguments"} =
             api(ws, "chat.startStream", %{"channel" => "C0GENERAL"})
  end

  test "the upload flow mints a URL, records bytes and shares to a channel", %{ws: ws} do
    %{"ok" => true, "file_id" => id, "upload_url" => url} =
      api(ws, "files.getUploadURLExternal", %{"filename" => "notes.txt", "length" => "11"})

    assert url == "http://127.0.0.1:4040/api/upload/#{id}"
    assert :ok = Workspace.record_upload(ws, id, 11)

    %{"ok" => true} =
      api(ws, "files.completeUploadExternal", %{
        "files" => [%{"id" => id, "title" => "Notes"}],
        "channel_id" => "C0GENERAL",
        "initial_comment" => "here you go"
      })

    assert [
             %{
               "text" => "here you go",
               "files" => [%{"id" => ^id, "title" => "Notes", "size" => 11} = file]
             }
           ] =
             messages(ws, "C0GENERAL")

    refute Map.has_key?(file, "pending")
  end

  test "chat.getPermalink links into the playground", %{ws: ws} do
    %{"ts" => ts} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "hi"})

    assert %{"ok" => true, "permalink" => "http://127.0.0.1:4040/archives/C0GENERAL/p" <> _} =
             api(ws, "chat.getPermalink", %{"channel" => "C0GENERAL", "message_ts" => ts})
  end

  test "unknown methods are stubbed ok:true and marked in the inspector", %{ws: ws} do
    assert %{"ok" => true} = api(ws, "team.info", %{})

    assert [%{"label" => "team.info", "stubbed" => true, "dir" => "out"} | _] =
             Workspace.snapshot(ws)["inspector"]
  end

  test "response_url semantics: ephemeral default, in_channel, replace and delete", %{ws: ws} do
    %{"ts" => ts} = api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "original"})

    "http://127.0.0.1:4040/respond/" <> token = Workspace.mint_response_url(ws, "C0GENERAL", ts)

    # default: a new ephemeral message
    %{"ok" => true} = Workspace.respond(ws, token, %{"text" => "only you"})
    assert [_, %{"text" => "only you", "ephemeral" => true}] = messages(ws, "C0GENERAL")

    # in_channel: visible message
    %{"ok" => true} =
      Workspace.respond(ws, token, %{"text" => "all", "response_type" => "in_channel"})

    assert [_, _, %{"text" => "all"} = visible] = messages(ws, "C0GENERAL")
    refute Map.has_key?(visible, "ephemeral")

    # replace_original rewrites the target message
    %{"ok" => true} =
      Workspace.respond(ws, token, %{"text" => "replaced", "replace_original" => true})

    assert [%{"ts" => ^ts, "text" => "replaced"}, _, _] = messages(ws, "C0GENERAL")

    # delete_original removes it
    %{"ok" => true} = Workspace.respond(ws, token, %{"delete_original" => true})
    refute Enum.any?(messages(ws, "C0GENERAL"), &(&1["ts"] == ts))

    assert :unknown_token = Workspace.respond(ws, "nope", %{"text" => "x"})
  end

  test "a slash-style response_url (no message) just posts", %{ws: ws} do
    "http://127.0.0.1:4040/respond/" <> token = Workspace.mint_response_url(ws, "C0GENERAL", nil)

    %{"ok" => true} = Workspace.respond(ws, token, %{"text" => "ack", "replace_original" => true})
    assert [%{"text" => "ack", "ephemeral" => true}] = messages(ws, "C0GENERAL")
  end

  test "subscribers get a snapshot on every change and drop on exit", %{ws: ws} do
    json = Workspace.subscribe(ws)
    assert %{"channels" => [_, _]} = JSON.decode!(json)

    api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "ping"})
    assert_receive {:playground, :state, json}
    assert %{"messages" => %{"C0GENERAL" => [%{"text" => "ping"}]}} = JSON.decode!(json)
  end

  test "the inspector is capped", %{ws: ws} do
    for n <- 1..250 do
      api(ws, "chat.postMessage", %{"channel" => "C0GENERAL", "text" => "m#{n}"})
    end

    assert length(Workspace.snapshot(ws)["inspector"]) == 200
  end

  test "human messages carry the dev user and thread over", %{ws: ws} do
    {:ok, %{"ts" => root}} = Workspace.put_human_message(ws, "C0GENERAL", "hello", nil)
    {:ok, reply} = Workspace.put_human_message(ws, "C0GENERAL", "in thread", root)

    assert %{"user" => "U0DEV", "thread_ts" => ^root} = reply
    assert [%{"reply_count" => 1}, _] = messages(ws, "C0GENERAL")
  end
end
