defmodule Slink.BlockKitTest do
  # async: false — the last test uses Slink.Testing.run/3 (global seams).
  use ExUnit.Case, async: false
  import Slink.BlockKit

  test "text objects" do
    assert mrkdwn("*hi*") == %{type: "mrkdwn", text: "*hi*"}
    assert plain_text("hi") == %{type: "plain_text", text: "hi", emoji: true}
    assert plain_text("hi", emoji: false).emoji == false
  end

  test "header uses plain text (Slack requires it), section defaults to mrkdwn" do
    assert header("Deploy").text.type == "plain_text"
    assert section("*bold*").text == %{type: "mrkdwn", text: "*bold*"}
  end

  test "section carries fields and an accessory" do
    block =
      section("main",
        fields: ["*a*", plain_text("b")],
        accessory: button("Go", action_id: "go")
      )

    assert [%{type: "mrkdwn", text: "*a*"}, %{type: "plain_text", text: "b"}] = block.fields
    assert block.accessory.action_id == "go"
    refute Map.has_key?(section("bare"), :fields)
  end

  test "buttons include only the options given" do
    assert button("Go") == %{type: "button", text: plain_text("Go")}

    full = button("Ship", action_id: "ship", value: "prod", style: "primary")
    assert %{action_id: "ship", value: "prod", style: "primary"} = full
  end

  test "context wraps bare strings as mrkdwn and passes elements through" do
    img = %{type: "image", image_url: "https://x/y.png", alt_text: "y"}
    assert context(["note", img]).elements == [mrkdwn("note"), img]
  end

  test "select menus and options" do
    select = static_select("Pick…", [option("Free", "free")], action_id: "plan")

    assert select.placeholder.text == "Pick…"
    assert [%{text: %{text: "Free"}, value: "free"}] = select.options
    assert select.action_id == "plan"
  end

  test "modal composes inputs into an openable view" do
    view =
      modal(
        "Settings",
        [
          input("Email", plain_text_input(action_id: "email"), hint: "work address"),
          input("Plan", static_select("Choose…", [option("Pro", "pro")], action_id: "plan"))
        ],
        submit: "Save",
        callback_id: "settings"
      )

    assert view.type == "modal"
    assert view.title.text == "Settings"
    assert view.submit.text == "Save"
    assert view.callback_id == "settings"

    assert [%{type: "input", label: %{text: "Email"}, hint: %{text: "work address"}} | _] =
             view.blocks
  end

  test "blocks are plain JSON-encodable maps" do
    blocks = [
      header("Deploy"),
      section("*prod*", accessory: button("Go", action_id: "go")),
      divider(),
      context(["updated just now"]),
      image("https://x/y.png", "graph", title: "trend"),
      actions([button("A", action_id: "a"), button("B", action_id: "b")])
    ]

    assert is_binary(JSON.encode!(blocks))
  end

  test "builders flow through reply/3 into a captured send" do
    defmodule BlockBot do
      use Slink
      import Slink.BlockKit

      @impl true
      def handle_event(_event, _context) do
        {:reply, "fallback", blocks: [section("hi"), actions([button("Go", action_id: "go")])]}
      end
    end

    run = Slink.Testing.run(BlockBot, Slink.Testing.event(:app_mention))

    assert [{"chat.postMessage", %{text: "fallback", blocks: [section, actions]}}] = run.calls
    assert section.type == "section"
    assert [%{action_id: "go"}] = actions.elements
  end
end
