defmodule Argus.Test.Fixtures.Decompression do
  @moduledoc """
  Fixtures for one-shot decompression, an unsafe_input sink.

  The positives are the three advisories' shapes: a socket handler
  inflating a frame's payload in one call (Bandit, GHSA-frh3-6pv6-rc8j),
  an HTTP client middleware gunzipping the body its `call/3` is handed
  (Tesla, GHSA-mc85-72gr-vm9f), and a request body inflated in a plug.
  The quiet ones inflate in bounded chunks, or decompress what the
  program wrote itself.
  """

  defmodule FrameHandler do
    @moduledoc "A ThousandIsland handler inflating each frame in one call."
    @behaviour ThousandIsland.Handler

    def handle_data(data, socket, %{z: z} = state) do
      payload = :zlib.inflate(z, <<data::binary, 0, 0, 255, 255>>)
      {:continue, Map.put(state, :last, {socket, payload})}
    end
  end

  defmodule BoundedFrameHandler do
    @moduledoc "Quiet: the fix, safeInflate in bounded chunks under a cap."
    @behaviour ThousandIsland.Handler

    def handle_data(data, _socket, %{z: z} = state) do
      {:continue, Map.put(state, :last, inflate(z, :zlib.safeInflate(z, data), [], 0))}
    end

    defp inflate(_z, _chunk, _acc, size) when size > 1_000_000, do: {:error, :too_big}
    defp inflate(_z, {:finished, out}, acc, _size), do: {:ok, [acc | out]}

    defp inflate(z, {:continue, out}, acc, size),
      do: inflate(z, :zlib.safeInflate(z, []), [acc | out], size + IO.iodata_length(out))
  end

  defmodule GzipBodyPlug do
    @moduledoc "A plug inflating the request body it is handed."
    @behaviour Plug

    def init(opts), do: opts

    def call(%{body: body} = conn, _opts), do: Map.put(conn, :decoded, :zlib.gunzip(body))
  end

  defmodule ClientMiddleware do
    @moduledoc "Tesla's shape: a middleware's exported call/3, called by no one in the program."
    def call(env, next, _opts) do
      {:ok, response} = next.(env)
      decompress(response.body)
    end

    defp decompress(body), do: :zlib.gunzip(body)
  end

  defmodule OwnData do
    @moduledoc "Quiet: what the program compressed itself, from a literal it wrote."
    @blob :zlib.gzip("seed data")

    def seed, do: :zlib.gunzip(@blob)
  end
end
