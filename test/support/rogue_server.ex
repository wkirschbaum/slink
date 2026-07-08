defmodule Slink.Test.RogueServer do
  @moduledoc """
  A raw-TCP WebSocket server that completes the handshake and then *misbehaves*,
  to exercise `Slink.SocketMode`'s error-handling paths that a well-behaved
  server (Bandit) can't reach:

    * `:drop` — closes the TCP socket abruptly with no close frame, so the client
      sees a transport error and reconnects.

  Returns `{:ok, ws_url}` from `start/2`. The listener self-terminates after
  handling one connection.
  """

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def start(test_pid, mode) when mode in [:drop] do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen, test_pid, mode) end)
    {:ok, "ws://127.0.0.1:#{port}/link"}
  end

  defp accept(listen, test_pid, mode) do
    {:ok, socket} = :gen_tcp.accept(listen)
    request = read_request(socket, "")
    key = extract_key(request)
    :gen_tcp.send(socket, handshake_response(key))
    send(test_pid, {:rogue, :connected})

    case mode do
      :drop -> :gen_tcp.close(socket)
    end

    :gen_tcp.close(listen)
  end

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      read_request(socket, acc <> data)
    end
  end

  defp extract_key(request) do
    [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, request)
    key
  end

  defp handshake_response(key) do
    accept = :crypto.hash(:sha, key <> @ws_guid) |> Base.encode64()

    "HTTP/1.1 101 Switching Protocols\r\n" <>
      "Upgrade: websocket\r\n" <>
      "Connection: Upgrade\r\n" <>
      "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
  end
end
