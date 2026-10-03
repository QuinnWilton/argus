defmodule Argus.Extractors.TermValidation do
  @moduledoc """
  Proves recursive non-executable term validators from their bytecode.

  Local summaries are partial-correctness contracts: an `ok` result implies
  recursively inert input, and all other normal results are error tuples. A
  greatest fixed point checks every contract body against the remaining local
  contracts. This is ordinary induction on terminating call depth, not a trust
  list of helper names. Container contracts additionally require list/map types
  or an exact tuple prefix; a maps:fold callback must validate both key and value
  on every normal return. Unknown control flow or exhausted budgets fail closed.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractors.SecurityValues
  alias Argus.Extractors.TermValidation.Proof
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations, do: [:decoded_term_validated]

  @impl true
  def extract(data) do
    decoders = Enum.filter(CallSites.for_module(data), &(&1.mfa == {:erlang, :binary_to_term, 2}))

    if decoders == [] do
      %{}
    else
      functions =
        Map.new(data.functions, fn {:function, name, arity, _, instrs} ->
          cfg = data |> Helpers.cfg(name, arity) |> SecurityValues.proof_cfg(instrs)
          {{data.module, name, arity}, %{instrs: instrs, cfg: cfg, arity: arity}}
        end)

      summaries = contracts(functions)

      rows =
        for site <- decoders,
            mfa =
              Enum.find_value(functions, fn {mfa, _} ->
                if InstrId.func_id(elem(mfa, 0), elem(mfa, 1), elem(mfa, 2)) == site.func_id,
                  do: mfa
              end),
            Proof.proves?(Map.fetch!(functions, mfa), {:decoder, site.idx}, summaries),
            do: [InstrId.mint(site.func_id, site.idx), site.func_id]

      Enum.reduce(Enum.sort(Enum.uniq(rows)), %{}, &add_fact(&2, :decoded_term_validated, &1))
    end
  end

  defp contracts(functions) do
    candidates =
      for {mfa, fun} <- functions,
          role <- roles(fun.arity),
          into: MapSet.new(),
          do: {mfa, role}

    narrow(candidates, functions)
  end

  defp roles(1), do: [:term, :list, :map]
  defp roles(2), do: [:tuple_prefix]
  defp roles(3), do: [:map_entry]
  defp roles(_), do: []

  defp narrow(candidates, functions) do
    next =
      MapSet.filter(candidates, fn {mfa, role} ->
        Proof.proves?(Map.fetch!(functions, mfa), role, candidates)
      end)

    if next == candidates, do: next, else: narrow(next, functions)
  end
end
