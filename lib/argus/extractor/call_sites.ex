defmodule Argus.Extractor.CallSites do
  @moduledoc """
  Every call instruction in a module, indexed once.

  Twelve extractors match remote calls against their own tables, and each
  used to walk every instruction of every function to find them: a
  module was scanned once per extractor, and the OTP extractor scanned it
  four times on its own. The pipeline now builds this index once per
  module and extractors filter it, which is a walk over the call sites
  (a few percent of the instructions) instead of the instruction stream.

  A site carries the same context the per-instruction scanners passed
  to their handlers — the function ID, the instruction list and the
  index — so the register-resolution helpers work unchanged.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Pipeline.Normalize

  @type site :: %{
          func_id: String.t(),
          instrs: [tuple()],
          idx: non_neg_integer(),
          mfa: {module(), atom(), arity()},
          remote?: boolean()
        }

  @doc "Indexes every remote and local call in `functions`."
  @spec index(module(), [tuple()]) :: [site()]
  def index(mod, functions) do
    Enum.flat_map(functions, fn {:function, name, arity, _entry, instrs} ->
      func_id = Normalize.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.flat_map(fn {instr, idx} ->
        case Helpers.match_remote_call(instr) do
          {:ok, m, f, a} ->
            [%{func_id: func_id, instrs: instrs, idx: idx, mfa: {m, f, a}, remote?: true}]

          :none ->
            case Helpers.match_local_call(instr) do
              {:ok, m, f, a} ->
                [%{func_id: func_id, instrs: instrs, idx: idx, mfa: {m, f, a}, remote?: false}]

              :none ->
                []
            end
        end
      end)
    end)
  end

  @doc """
  The index for `module_data`: the one the pipeline attached, or a fresh
  one when an extractor is called on bare disassembly (as its unit tests
  do).
  """
  @spec for_module(map()) :: [site()]
  def for_module(%{call_sites: sites}) when is_list(sites), do: sites
  def for_module(%{module: mod, functions: functions}), do: index(mod, functions)
end
