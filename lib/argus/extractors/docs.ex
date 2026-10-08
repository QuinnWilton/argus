defmodule Argus.Extractors.Docs do
  @moduledoc """
  Functions the module's documentation hides from its users, read from
  the beam's Docs chunk (EEP 48).

  A library exports more than its users call: the helpers its own
  modules share, and the functions its macros and module bodies call at
  compile time (`SQL.BNF`, a `@moduledoc false` module whose grammar is
  parsed while `SQL.Lexer` compiles). Elixir records which exports the
  author left out of the documentation, `@doc false` on a function and
  `@moduledoc false` on a module, and rules that treat every export as
  a way in for a caller's data ask for them (`unsafe_input.dl`'s
  `outside_api`).

  ## Emitted facts

  - `doc_hidden(func)`: `func` is an exported function whose doc entry
    is `:hidden`, at every arity its default arguments define, or any
    exported function of a module whose moduledoc is `:hidden`. Macros
    are left out: no rule counts them as a runtime way in.

  `@impl true` hides a callback too, so a rule reading this fact
  decides itself whether the function is a behaviour's callback. A beam
  without a Docs chunk (compiled with `docs: false`, or Erlang without
  `-moduledoc`) or with one this cannot read yields nothing: no export
  is hidden.
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Facts, only: [add_fact: 3]

  alias Argus.Extractor.Helpers
  alias Argus.InstrId

  @impl true
  def relations, do: [:doc_hidden]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    exported = exported(module_data)

    module_data
    |> hidden()
    |> Enum.filter(&MapSet.member?(exported, &1))
    |> Enum.sort()
    |> Enum.reduce(%{}, fn {name, arity}, acc ->
      add_fact(acc, :doc_hidden, [InstrId.func_id(mod, name, arity)])
    end)
  end

  # The functions the module exports, as {name, arity}.
  defp exported(%{exports: exports}) do
    MapSet.new(exports, fn
      {name, arity, _label} -> {name, arity}
      # beam_disasm's format.
      {:atom, name, arity, _label} -> {name, arity}
    end)
  end

  # The functions the Docs chunk hides, as {name, arity}: every one of
  # a hidden module, else each whose own doc is hidden. Only functions
  # the source defines have entries; macros' are `:macro` entries.
  defp hidden(module_data) do
    case docs(module_data) do
      {:ok, moduledoc, entries} ->
        for {{:function, name, arity}, _anno, _signature, doc, meta} <- entries,
            moduledoc == :hidden or doc == :hidden,
            is_atom(name) and is_integer(arity),
            arity <- (arity - defaults(meta))..arity//1,
            do: {name, arity}

      :error ->
        []
    end
  end

  # A definition with default arguments has one doc entry, at its full
  # arity, and exports every shorter arity down to its required ones.
  defp defaults(%{defaults: n}) when is_integer(n) and n > 0, do: n
  defp defaults(_meta), do: 0

  defp docs(module_data) do
    with {:ok, source} <- Helpers.beam_source(module_data),
         {:ok, {_module, [{~c"Docs", chunk}]}} <- :beam_lib.chunks(source, [~c"Docs"]),
         {:docs_v1, _anno, _language, _format, moduledoc, _meta, entries} when is_list(entries) <-
           :erlang.binary_to_term(chunk) do
      {:ok, moduledoc, entries}
    else
      _ -> :error
    end
  rescue
    # A chunk that does not decode is no chunk.
    ArgumentError -> :error
  end
end
