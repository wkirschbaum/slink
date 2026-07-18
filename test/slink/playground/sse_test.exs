defmodule Slink.Playground.SSETest do
  # The /events stream never returns, so it needs a real socket, not Plug.Test.
  use ExUnit.Case, async: false

  @name PlaygroundSSETest

  setup do
    %{base: Slink.Test.PlaygroundSetup.start!(@name)}
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

    # Background activity (the boot-time auth.test) may broadcast frames of its
    # own — scan until the posted message shows up.
    assert await_frame(socket, fn state ->
             match?(%{"messages" => %{"C0GENERAL" => [%{"text" => "ping"}]}}, state)
           end)

    :gen_tcp.close(socket)
  end

  defp await_frame(socket, fun, tries \\ 10) do
    cond do
      tries == 0 -> false
      fun.(decode_frame(read_frame(socket))) -> true
      true -> await_frame(socket, fun, tries - 1)
    end
  end

  # Read until a complete `data: …` line has arrived (frames are single lines).
  defp read_frame(socket, acc \\ "") do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    acc = acc <> data
    if Regex.match?(~r/data: .+\n/, acc), do: acc, else: read_frame(socket, acc)
  end

  # One read may carry several frames; the last data line is the newest state.
  defp decode_frame(data) do
    [_, json] = ~r/data: (.*)/ |> Regex.scan(data) |> List.last()
    JSON.decode!(json)
  end
end
