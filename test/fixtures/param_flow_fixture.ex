defmodule Argus.Test.Fixtures.ParamFlow do
  @moduledoc false

  # The shapes the extractor must read: head destructuring, a second
  # clause, binary construction, a decoder, a store-shaped read, a closure
  # capture, forwarding, and a literal.

  defmodule Store do
    @moduledoc false
    # Not a propagator: whatever it returns is fresh, however it was asked.
    def load(id), do: Process.get(id)
  end

  defmodule Shapes do
    @moduledoc false

    def concat(p), do: String.to_atom("field_" <> p)
    def bin(<<"pre_", rest::binary>>), do: String.to_atom(rest)
    def head(%{"name" => name}, _socket), do: String.to_atom(name)
    def second(:ignored, _params, _socket), do: :ok
    def second(_, params, _socket), do: String.to_atom(params["order_by"])
    def decoded(body), do: body |> JSON.decode!() |> Map.get("kind") |> String.to_atom()
    def loaded(id), do: id |> Store.load() |> String.to_atom()
    def forwarded(a, b), do: helper(b, a)
    def helper(_x, _y), do: :ok
    def captured(prefix, xs), do: Enum.each(xs, fn x -> String.to_atom(prefix <> x) end)
    def literal(_p), do: String.to_atom("fixed")

    # `a` dies first, so the frame is trimmed and `b` and `c` move down a
    # slot each: the calls after the trim read b and c from renumbered
    # slots, one each.
    def trimmed(a, b, c) do
      first = :erlang.phash2(a)
      :ok = Process.put(:first, first)
      :ok = Process.put(:c, c)
      Process.put(:a, a)
      _ = :erlang.atom_to_list(b)
      :erlang.binary_to_list(c)
    end
  end
end
