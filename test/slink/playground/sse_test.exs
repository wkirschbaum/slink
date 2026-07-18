defmodule Slink.Playground.SSETest do
  # The /events stream never returns, so it needs a real socket, not Plug.Test.
  use ExUnit.Case, async: false

  @name PlaygroundSSETest

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

    %{base: Slink.Playground.url(@name)}
  end

  test "the UI page is served", %{base: base} do
    resp = Req.get!(base <> "/")
    assert resp.status == 200
    assert resp.body =~ "Slink Playground"
    assert resp.body =~ "EventSource"
  end

  test "/events sends a snapshot immediately and again on every change", %{base: base} do
    %{port: port} = URI.parse(base)

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    :ok = :gen_tcp.send(socket, "GET /events HTTP/1.1\r\nhost: localhost\r\n\r\n")

    first = read_frame(socket)
    assert first =~ "content-type: text/event-stream"
    assert first =~ "event: state"
    assert %{"channels" => [_, _]} = decode_frame(first)

    {:ok, _} = Slink.API.post_message("xoxb-playground", "C0GENERAL", "ping")

    frame = read_frame(socket)
    assert %{"messages" => %{"C0GENERAL" => [%{"text" => "ping"}]}} = decode_frame(frame)

    :gen_tcp.close(socket)
  end

  # Read until a complete `data: …` line has arrived (frames are single lines).
  defp read_frame(socket, acc \\ "") do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    acc = acc <> data
    if Regex.match?(~r/data: .+\n/, acc), do: acc, else: read_frame(socket, acc)
  end

  defp decode_frame(data) do
    [_, json] = Regex.run(~r/data: (.*)/, data)
    JSON.decode!(json)
  end
end
