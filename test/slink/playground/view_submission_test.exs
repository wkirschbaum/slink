defmodule Slink.Playground.ViewSubmissionTest do
  # The modal sync-ack round trip: submit from the browser, the handler's
  # {:ack, ...} drives both the HTTP response and the modal stack.
  use ExUnit.Case, async: false

  alias Slink.Playground.Workspace

  @name PlaygroundModalTest
  @ws Module.concat(@name, :Workspace)

  setup do
    stub = Application.get_env(:slink, :identity_fetch)
    Application.delete_env(:slink, :identity_fetch)

    start_supervised!(
      {Slink.Playground, module: Slink.Test.PlaygroundTestBot, port: 0, name: @name}
    )

    on_exit(fn ->
      Application.put_env(:slink, :identity_fetch, stub)
      Application.delete_env(:slink, :api_base_url)
    end)

    base = Slink.Playground.url(@name)
    Workspace.subscribe(@ws)

    # /modal makes the bot open its modal through the real views.open path.
    Req.post!(base <> "/ui/slash", json: %{channel: "C0GENERAL", command: "/modal", text: ""})
    state = await_state(fn state -> state["views"]["stack"] != [] end)
    [%{"id" => view_id}] = state["views"]["stack"]

    %{base: base, view_id: view_id}
  end

  test "an invalid submit returns the errors ack and keeps the modal", %{
    base: base,
    view_id: view_id
  } do
    body =
      Req.post!(base <> "/ui/view_submission", json: %{view_id: view_id, values: %{}}).body

    assert %{"ok" => true, "ack" => %{"response_action" => "errors", "errors" => errors}} = body
    assert errors["note"] == "say something"
    assert [%{"id" => ^view_id}] = Workspace.snapshot(@ws)["views"]["stack"]
  end

  test "a valid submit closes the modal", %{base: base, view_id: view_id} do
    values = %{"note" => %{"note" => %{"type" => "plain_text_input", "value" => "hello"}}}

    body =
      Req.post!(base <> "/ui/view_submission", json: %{view_id: view_id, values: values}).body

    assert %{"ok" => true, "ack" => ack} = body
    assert ack == %{}
    assert Workspace.snapshot(@ws)["views"]["stack"] == []
  end

  test "closing the modal from the UI pops it", %{base: base, view_id: view_id} do
    assert %{"ok" => true} =
             Req.post!(base <> "/ui/view_closed", json: %{view_id: view_id}).body

    assert Workspace.snapshot(@ws)["views"]["stack"] == []
  end

  defp await_state(fun) do
    assert_receive {:playground, :state, json}, 2_000
    state = JSON.decode!(json)
    if fun.(state), do: state, else: await_state(fun)
  end
end
