defmodule Argus.Extractors.Specs do
  @moduledoc """
  What the specs of a module's functions, and of the remote functions it
  calls, claim they return.

  ## Emitted facts

  - `spec_return(func, shape, origin)` — one row per shape
    `Argus.Specs` reads from a spec: `can_fail`, `total`, `no_return`,
    `returns_pid`. `origin` is `analyzed` for the module's own functions
    (read from its beam) and `installed` for a remote callee (read from
    the code path, memoized per module). A function with no row is
    unknown.

  Specs are claims nothing verified, so the rules that read these rows use
  them to stay quiet (a callee whose spec is `true` has no failure to
  check) or to confirm, never to report on their own. The installed rows
  depend on the code path the extraction runs with; a cache keyed on
  extraction output folds in `Argus.Specs.environment_digest/1`.
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers, only: [add_fact: 3]

  alias Argus.Extractor.CallSites
  alias Argus.Pipeline.Normalize
  alias Argus.Specs

  @impl true
  def relations, do: [:spec_return]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module

    %{}
    |> emit_own(mod, own_specs(module_data))
    |> emit_callees(
      mod,
      CallSites.for_module(module_data),
      Map.get(module_data, :installed_specs)
    )
  end

  # The pipeline hands over the beam it disassembled; an extractor run on
  # bare disassembly (a unit test) reads the module from the code path.
  defp own_specs(%{beam: beam}) when is_binary(beam) do
    case Specs.of_beam(beam) do
      {:ok, returns} -> returns
      :error -> %{}
    end
  end

  defp own_specs(%{module: mod}) do
    case Specs.installed(mod) do
      :unknown -> %{}
      returns -> returns
    end
  end

  defp emit_own(facts, mod, returns) do
    for {{name, arity}, shapes} <- Enum.sort(returns),
        shape <- shapes,
        reduce: facts do
      acc ->
        add_fact(acc, :spec_return, [
          Normalize.func_id(mod, name, arity),
          to_string(shape),
          "analyzed"
        ])
    end
  end

  defp emit_callees(facts, mod, sites, memo) do
    callees =
      for %{remote?: true, mfa: {m, _f, _a} = mfa} <- sites, m != mod, uniq: true, do: mfa

    installed =
      callees
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Map.new(&{&1, Specs.installed(&1, memo)})

    for {m, f, a} <- Enum.sort(callees),
        %{} = returns <- [Map.fetch!(installed, m)],
        shape <- Map.get(returns, {f, a}, []),
        reduce: facts do
      acc ->
        add_fact(acc, :spec_return, [Normalize.func_id(m, f, a), to_string(shape), "installed"])
    end
  end
end
