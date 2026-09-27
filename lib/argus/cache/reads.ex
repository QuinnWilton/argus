defmodule Argus.Cache.Reads do
  @moduledoc """
  What a producer read of the schema (`Argus.Schema`) while it ran: the
  part of its rows' key its code does not name.

  A producer's shard is keyed on its code (`Argus.Cache.Code`), but not
  on `Argus.Schema`'s: the schema's modules hold every relation as
  literals, and keyed as code, any edit to any relation moved every
  producer's key. A producer depends on the entries it reads — the
  pipeline decodes a few Layer-1 relations by their columns, and
  nothing else — so each accessor of the schema records the entry it
  returned, and a store keys the rows on what those entries are when
  it looks them up (`Argus.Cache.Facts`).

  Recording is `Argus.Schema.Reads`'s (`record/2` and `track/1` here
  are its); this module is what a store keys a read on (`digest/1`).
  """

  @typedoc "A read of the schema (`Argus.Schema.Reads`)."
  @type read :: Argus.Schema.Reads.read()

  @doc "Records `read`: `Argus.Schema.Reads.record/2`."
  @spec record(read(), value) :: value when value: term()
  defdelegate record(read, value), to: Argus.Schema.Reads

  @doc "Runs `fun`, recording its reads: `Argus.Schema.Reads.track/1`."
  @spec track((-> result)) :: {result, [read()]} when result: term()
  defdelegate track(fun), to: Argus.Schema.Reads

  @doc """
  The digest of what `read` names now (`Argus.Schema.reread/1`), as
  lowercase hex: what a key holds for it.
  """
  @spec digest(read()) :: String.t()
  def digest(read) when is_binary(read), do: read |> Argus.Schema.reread() |> value_digest()

  @doc """
  The digest of a value a read names: SHA-256 of its deterministic
  external term, as lowercase hex.
  """
  @spec value_digest(term()) :: String.t()
  def value_digest(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
