defmodule Slink.Playground.WebApiTest do
  # The playground points the process-global :api_base_url at itself.
  use ExUnit.Case, async: false

  alias Slink.Playground.Workspace

  @token "xoxb-playground"

  setup do
    # Let the boot-time auth.test resolve through the playground's fake API
    # instead of the suite-wide :identity_fetch stub.
    stub = Application.get_env(:slink, :identity_fetch)
    Application.delete_env(:slink, :identity_fetch)

    start_supervised!(
      {Slink.Playground, module: Slink.Test.PlaygroundTestBot, port: 0, name: PlaygroundApiTest}
    )

    on_exit(fn ->
      Application.put_env(:slink, :identity_fetch, stub)
      Application.delete_env(:slink, :api_base_url)
    end)

    %{ws: PlaygroundApiTest.Workspace}
  end

  test "boot points the Web API at the playground and resolves the bot identity" do
    base = Slink.Playground.url(PlaygroundApiTest)
    assert Application.get_env(:slink, :api_base_url) == base <> "/api"

    assert await(fn -> Slink.Identity.bot_user_id(@token) == "U0BOT" end)
  end

  test "Slink.API calls land in the workspace over real HTTP", %{ws: ws} do
    assert {:ok, %{"ts" => ts}} = Slink.API.post_message(@token, "C0GENERAL", "hello")
    assert {:ok, _body} = Slink.API.update_message(@token, "C0GENERAL", ts, "edited")
    assert {:ok, _body} = Slink.API.add_reaction(@token, "C0GENERAL", ts, "eyes")

    assert [%{"text" => "edited", "reactions" => [%{"name" => "eyes"}]}] =
             Workspace.snapshot(ws)["messages"]["C0GENERAL"]

    assert {:error, "channel_not_found"} = Slink.API.post_message(@token, "C0NOPE", "hi")
  end

  test "views open through the real client", %{ws: ws} do
    assert {:ok, %{"view" => %{"id" => id}}} =
             Slink.API.open_view(@token, "trigger", %{type: "modal", callback_id: "hi"})

    assert %{"views" => %{"stack" => [%{"id" => ^id, "callback_id" => "hi"}]}} =
             Workspace.snapshot(ws)
  end

  test "the three-step upload flow works end to end", %{ws: ws} do
    assert {:ok, _body} =
             Slink.API.upload_file(@token, "hello bytes",
               filename: "hi.txt",
               title: "Hi",
               channel: "C0GENERAL",
               initial_comment: "a file"
             )

    assert [%{"text" => "a file", "files" => [file]}] =
             Workspace.snapshot(ws)["messages"]["C0GENERAL"]

    assert %{"title" => "Hi", "size" => 11} = file
  end

  test "a minted response_url accepts Slink.API.respond/2", %{ws: ws} do
    url = Workspace.mint_response_url(ws, "C0GENERAL", nil)

    assert {:ok, _body} = Slink.API.respond(url, %{text: "ephemeral ack"})

    assert [%{"text" => "ephemeral ack", "ephemeral" => true}] =
             Workspace.snapshot(ws)["messages"]["C0GENERAL"]
  end

  defp await(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && await(fun, tries - 1)
    end
  end
end
