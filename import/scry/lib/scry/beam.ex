defmodule Scry.Beam do
  @moduledoc """
  The analysis-relevant view of a `.beam` file.

  Elixir rewrites a module's beam when a compile-time dependency is
  recompiled even if nothing in the module changed: the `ExCk` chunk (the
  type checker's signature cache) is regenerated, and `Docs` moves with
  any `@doc` edit. Neither feeds fact extraction, so hashing or memoizing
  the raw bytes made a comment-only edit in one module re-extract every
  module that depends on it at compile time. `canonical/1` drops those
  chunks and rebuilds the module, so two beams that differ only there
  compare equal.

  `Dbgi` stays: planchette's debug twin recompiles from it.
  """

  @dropped [~c"ExCk", ~c"Docs"]

  @doc """
  Rebuilds `beam` without the chunks extraction never reads.

  A binary `:beam_lib` cannot parse is returned unchanged; the extractor
  reports the real problem downstream.
  """
  @spec canonical(binary()) :: binary()
  def canonical(beam) when is_binary(beam) do
    case :beam_lib.all_chunks(beam) do
      {:ok, _module, chunks} ->
        kept = Enum.reject(chunks, fn {id, _data} -> id in @dropped end)
        {:ok, rebuilt} = :beam_lib.build_module(kept)
        rebuilt

      {:error, :beam_lib, _reason} ->
        beam
    end
  end
end
