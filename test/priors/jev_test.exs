defmodule Argus.Priors.JevTest do
  @moduledoc """
  `Argus.Priors.Jev` against a local HTTP/1.1 endpoint that keeps
  connections alive, as the real one does.
  """

  use ExUnit.Case, async: true

  alias Argus.Priors.Jev

  # Answers every POST with one noul after holding it until `gate`
  # requests are being handled at once (or a second has passed), and
  # records the most it saw at once. Connections are kept alive.
  defmodule Endpoint do
    def start(gate) do
      # The default backlog of 5 resets a burst of connects on macOS.
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, backlog: 128])

      {:ok, port} = :inet.port(listen)
      counter = :atomics.new(2, [])
      acceptor = spawn_link(fn -> accept(listen, counter, gate) end)
      :ok = :gen_tcp.controlling_process(listen, acceptor)
      %{url: "http://127.0.0.1:#{port}/v1/systemone", counter: counter}
    end

    def peak(%{counter: counter}), do: :atomics.get(counter, 2)

    defp accept(listen, counter, gate) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          pid = spawn(fn -> serve(socket, counter, gate, "") end)
          :ok = :gen_tcp.controlling_process(socket, pid)
          accept(listen, counter, gate)

        {:error, _} ->
          :ok
      end
    end

    defp serve(socket, counter, gate, buffer) do
      case read_request(socket, buffer) do
        {:ok, rest} ->
          n = :atomics.add_get(counter, 1, 1)
          :atomics.put(counter, 2, max(n, :atomics.get(counter, 2)))
          wait_for(counter, gate, System.monotonic_time(:millisecond) + 1_000)
          :atomics.sub(counter, 1, 1)

          body =
            ~s({"model":"jev-test","answers":{"q":{"type":"noul","noul":0.5}},"usage":{"input_tokens":3}})

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n",
              "content-length: #{byte_size(body)}\r\n\r\n",
              body
            ])

          serve(socket, counter, gate, rest)

        :closed ->
          :ok
      end
    end

    defp read_request(socket, buffer) do
      with [head, rest] <- :binary.split(buffer, "\r\n\r\n"),
           [_, length] <- Regex.run(~r/content-length:\s*(\d+)/i, head),
           length = String.to_integer(length),
           true <- byte_size(rest) >= length do
        {:ok, binary_part(rest, length, byte_size(rest) - length)}
      else
        _ ->
          case :gen_tcp.recv(socket, 0) do
            {:ok, data} -> read_request(socket, buffer <> data)
            {:error, _} -> :closed
          end
      end
    end

    defp wait_for(counter, gate, deadline) do
      cond do
        :atomics.get(counter, 2) >= gate ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          :timeout

        true ->
          Process.sleep(5)
          wait_for(counter, gate, deadline)
      end
    end
  end

  @request %{
    model: "jev-test",
    state: %{text: "hello"},
    questions: %{"q" => %{type: "noul", instructions: "The text is a greeting."}}
  }

  test "requests after the first each get a connection of their own, not a queue" do
    endpoint = Endpoint.start(8)
    opts = [endpoint: endpoint.url, api_key: "test", max_attempts: 1]

    # One request first leaves an idle keep-alive connection: on httpc's
    # default profile the next ones would queue behind it, one at a time.
    assert {:ok, %{answers: %{"q" => %{"noul" => 0.5}}}} = Jev.ask(@request, opts)

    results =
      1..8
      |> Task.async_stream(fn _ -> Jev.ask(@request, opts) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{usage: %{"input_tokens" => 3}}}, &1))
    assert Endpoint.peak(endpoint) == 8
  end
end
