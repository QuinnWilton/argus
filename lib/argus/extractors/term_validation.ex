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

  It also says what the bytes a decoder decodes are, by exact identity
  (`Argus.Extractors.SecurityValues.identity_at/3`): `decoded_bytes_value`
  names, at each decoding call (`ApiCalls.deserialization_sink?/1`), the
  function's parameter they are or the remote call whose result they are
  projected from, with the projection's path (`tuple:1/map:"blob"`). Where they
  are a parameter, the same is said at each local call of that function in the
  module, for the argument at that position, so the rules can follow one hop
  into a private decoding helper. A join of values, a value computed by an
  instruction, or a local helper's result has no row.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Terms
  alias Argus.Extractors.ApiCalls
  alias Argus.Extractors.SecurityValues
  alias Argus.Extractors.TermValidation.Proof
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations, do: [:decoded_term_validated, :decoded_bytes_value]

  @impl true
  def extract(data) do
    sites = CallSites.for_module(data)

    data
    |> validated(sites)
    |> emit_bytes_values(data, sites)
  end

  defp validated(data, sites) do
    decoders = Enum.filter(sites, &(&1.mfa == {:erlang, :binary_to_term, 2}))

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

  # ── What the decoded bytes are ───────────────────────────────────────

  defp emit_bytes_values(facts, data, sites) do
    decoders = Enum.filter(sites, &(&1.remote? and ApiCalls.deserialization_sink?(&1.mfa)))

    decoded =
      for site <- decoders,
          value = SecurityValues.identity_at(site.instrs, site.idx, {:x, 0}),
          row = bytes_row(site, 0, value),
          row != nil,
          do: {site, value, row}

    # The parameters a decoder's bytes are, by function: what each local
    # call of it hands there is asked too.
    params =
      for {site, {:param, pos}, _row} <- decoded,
          into: MapSet.new(),
          do: {site.func_id, pos}

    callers =
      for site <- sites,
          not site.remote?,
          {mod, name, arity} = site.mfa,
          mod == data.module,
          callee = InstrId.func_id(mod, name, arity),
          pos <- 0..(arity - 1)//1,
          MapSet.member?(params, {callee, pos}),
          row = bytes_row(site, pos, SecurityValues.identity_at(site.instrs, site.idx, {:x, pos})),
          row != nil,
          do: row

    (Enum.map(decoded, &elem(&1, 2)) ++ callers)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(facts, &add_fact(&2, :decoded_bytes_value, &1))
  end

  defp bytes_row(site, pos, {:param, n}),
    do: bytes_prefix(site, pos) ++ [to_string(n), "", ""]

  defp bytes_row(site, pos, value) do
    with {at, path} <- projection(value, []),
         {:ok, mod, fun, arity} <- Helpers.match_remote_call(Reaching.at(site.instrs, at)) do
      bytes_prefix(site, pos) ++ ["-1", InstrId.func_id(mod, fun, arity), Enum.join(path, "/")]
    else
      _ -> nil
    end
  end

  defp bytes_prefix(site, pos),
    do: [InstrId.mint(site.func_id, site.idx), site.func_id, to_string(pos)]

  # The call a value is projected out of, and the projection's path from
  # the call's result outward: `{:field, {:field, {:call, 9}, :tuple, 1},
  # :map, "blob"}` is the call at 9, `["tuple:1", "map:\"blob\""]`.
  defp projection({:call, at}, path), do: {at, path}

  defp projection({:field, parent, :tuple, n}, path),
    do: projection(parent, ["tuple:#{n}" | path])

  defp projection({:field, parent, :map, key}, path),
    do: projection(parent, ["map:#{Terms.spell(key)}" | path])

  defp projection(_value, _path), do: nil

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
