defmodule Argus.Extractors.AtomSafety do
  @moduledoc """
  Atom safety extractor.

  Detects unsafe atom creation from dynamic input, unsafe deserialization,
  and dynamic code execution. The BEAM atom table is fixed-size (~1M entries)
  and never garbage collected, making any path converting untrusted input
  to atoms a denial-of-service vector.

  ## Emitted facts

  - `unsafe_atom_creation(id, func, api)` — `String.to_atom/1`, `:erlang.binary_to_atom/1,2`,
    `:erlang.list_to_atom/1`
  - `unsafe_deserialization(id, func, api, safety)` — `:erlang.binary_to_term/1` (always unsafe),
    `/2` (resolved for `[:safe]` option)
  - `code_execution(id, func, api)` — `Code.eval_string`, `Code.compile_string`,
    `:os.cmd`, `System.cmd`
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers, only: [add_fact: 3, match_remote_call: 1, resolve_register: 3]

  alias Argus.Normalize

  # APIs that create atoms from dynamic input. These can grow the atom
  # table unboundedly. The `*_to_existing_atom` variants are excluded
  # because they only look up existing atoms and cannot exhaust the table.
  @unsafe_atom_apis [
    {String, :to_atom, 1},
    {:erlang, :binary_to_atom, 1},
    {:erlang, :binary_to_atom, 2},
    {:erlang, :list_to_atom, 1}
  ]

  # APIs that execute dynamic code.
  @code_exec_apis [
    {Code, :eval_string, 1},
    {Code, :eval_string, 2},
    {Code, :eval_string, 3},
    {Code, :compile_string, 1},
    {Code, :compile_string, 2},
    {:os, :cmd, 1},
    {:os, :cmd, 2},
    {System, :cmd, 2},
    {System, :cmd, 3},
    {System, :shell, 1},
    {System, :shell, 2}
  ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Emitter.facts()
  def extract(module_data) do
    mod = module_data.module
    functions = module_data.functions

    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, facts ->
      func_id = Normalize.func_id(mod, name, arity)
      scan_instructions(facts, func_id, instrs)
    end)
  end

  defp scan_instructions(facts, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case match_remote_call(instr) do
        {:ok, mod, func, arity} ->
          id = "#{func_id}##{idx}"

          acc
          |> maybe_atom_creation(id, func_id, mod, func, arity)
          |> maybe_deserialization(id, func_id, mod, func, arity, instrs, idx)
          |> maybe_code_execution(id, func_id, mod, func, arity)

        :none ->
          acc
      end
    end)
  end

  defp maybe_atom_creation(facts, id, func_id, mod, func, arity) do
    if {mod, func, arity} in @unsafe_atom_apis do
      api = "#{inspect(mod)}.#{func}/#{arity}"
      add_fact(facts, :unsafe_atom_creation, [id, func_id, api])
    else
      facts
    end
  end

  defp maybe_deserialization(facts, id, func_id, :erlang, :binary_to_term, 1, _instrs, _idx) do
    add_fact(facts, :unsafe_deserialization, [
      id,
      func_id,
      ":erlang.binary_to_term/1",
      "unsafe"
    ])
  end

  defp maybe_deserialization(facts, id, func_id, :erlang, :binary_to_term, 2, instrs, idx) do
    safety =
      case resolve_register(instrs, idx, {:x, 1}) do
        {:ok, opts} when is_list(opts) ->
          if :safe in opts, do: "safe", else: "unsafe"

        _ ->
          "dynamic"
      end

    add_fact(facts, :unsafe_deserialization, [
      id,
      func_id,
      ":erlang.binary_to_term/2",
      safety
    ])
  end

  defp maybe_deserialization(facts, _id, _func_id, _mod, _func, _arity, _instrs, _idx), do: facts

  defp maybe_code_execution(facts, id, func_id, mod, func, arity) do
    if {mod, func, arity} in @code_exec_apis do
      api = "#{inspect(mod)}.#{func}/#{arity}"
      add_fact(facts, :code_execution, [id, func_id, api])
    else
      facts
    end
  end
end
