defmodule Slink.Playground.LoopTest do
  # The full circle over real HTTP: browser-shaped posts to /ui/* dispatch real
  # events; the bot's replies come back through the real rate limiter and Web
  # API client into the fake workspace.
  use ExUnit.Case, async: false

  alias Slink.Playground.Workspace

  @name PlaygroundLoopTest
  @ws Module.concat(@name, :Workspace)
  @token "xoxb-playground"

  setup do
    stub = Application.get_env(:slink, :identity_fetch)
    Application.delete_env(:slink, :identity_fetch)
    # Don't make every test wait out Slack's 1s/channel pacing.
    Application.put_env(:slink, :rate_interval_ms, 10)

    start_supervised!(
      {Slink.Playground, module: Slink.Test.PlaygroundTestBot, port: 0, name: @name}
    )

    on_exit(fn ->
      Application.put_env(:slink, :identity_fetch, stub)
      Application.delete_env(:slink, :api_base_url)
      Application.delete_env(:slink, :rate_interval_ms)
    end)

    Workspace.subscribe(@ws)
    %{base: Slink.Playground.url(@name)}
  end

  test "a mention in the UI comes back as the bot's reply", %{base: base} do
    post(base, "/ui/message", %{channel: "C0GENERAL", text: "yo <@U0BOT>"})

    state =
      await_state(fn state ->
        Enum.any?(general(state), &(&1["user"] == "U0BOT" and &1["text"] == "hi <@U0DEV>!"))
      end)

    # The human's message is there too, and both deliveries were logged.
    assert Enum.any?(general(state), &(&1["user"] == "U0DEV"))
    labels = Enum.map(state["inspector"], & &1["label"])
    assert "message" in labels and "app_mention" in labels
  end

  test "a slash command is answered ephemerally through its response_url", %{base: base} do
    post(base, "/ui/slash", %{channel: "C0GENERAL", command: "/echo", text: "hi there"})

    await_state(fn state ->
      Enum.any?(general(state), fn msg ->
        msg["ephemeral"] == true and msg["text"] == "you said: hi there"
      end)
    end)
  end

  test "a button click reaches the bot, which replaces the original message", %{base: base} do
    blocks = [
      Slink.BlockKit.actions([Slink.BlockKit.button("Go", action_id: "go", value: "prod")])
    ]

    {:ok, %{"ts" => ts}} =
      Slink.API.post_message(@token, "C0GENERAL", "pick one", %{blocks: blocks})

    post(base, "/ui/action", %{
      channel: "C0GENERAL",
      message_ts: ts,
      action: %{type: "button", action_id: "go", value: "prod"}
    })

    await_state(fn state ->
      Enum.any?(general(state), &(&1["ts"] == ts and &1["text"] == "clicked prod"))
    end)
  end

  test "a user reaction lands on the message and dispatches an event", %{base: base} do
    {:ok, %{"ts" => ts}} = Slink.API.post_message(@token, "C0GENERAL", "react to me")

    post(base, "/ui/reaction", %{op: "add", channel: "C0GENERAL", ts: ts, name: "tada"})

    await_state(fn state ->
      msg = Enum.find(general(state), &(&1["ts"] == ts))

      match?([%{"name" => "tada", "users" => ["U0DEV"]}], msg && msg["reactions"]) and
        Enum.any?(state["inspector"], &(&1["label"] == "reaction_added"))
    end)
  end

  test "opening the Home tab makes the bot publish its view", %{base: base} do
    post(base, "/ui/home_opened", %{})

    await_state(fn state ->
      case state["views"]["home"] do
        %{"blocks" => [%{"text" => %{"text" => "welcome home"}}]} -> true
        _ -> false
      end
    end)
  end

  test "redelivering an envelope is deduped, like a Slack retry", %{base: base} do
    post(base, "/ui/message", %{channel: "C0GENERAL", text: "yo <@U0BOT>"})

    state = await_state(fn state -> Enum.any?(general(state), &(&1["user"] == "U0BOT")) end)

    entry = Enum.find(state["inspector"], &(&1["label"] == "app_mention"))
    assert %{"ok" => true} = post(base, "/ui/redeliver", %{entry_id: entry["id"]})

    # The dispatcher drops the duplicate synchronously; give a wrongly started
    # handler ample time to have replied before counting.
    Process.sleep(300)
    replies = Enum.count(general(Workspace.snapshot(@ws)), &(&1["user"] == "U0BOT"))
    assert replies == 1
  end

  defp post(base, path, body) do
    Req.post!(base <> path, json: body).body
  end

  defp general(state), do: state["messages"]["C0GENERAL"]

  defp await_state(fun) do
    assert_receive {:playground, :state, json}, 2_000
    state = JSON.decode!(json)
    if fun.(state), do: state, else: await_state(fun)
  end
end
