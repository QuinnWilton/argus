defmodule Argus.Test.Soundness.Case do
  @moduledoc """
  What the soundness tests ask of a set of fixtures: every finding's
  severity by module, function and title, and one relation's rows.
  """

  alias Argus.Test.Memo

  @doc "`{module suffix, function, title} => severity` for `analyses` over `modules`."
  @spec severities([module()], [atom()]) :: %{{String.t(), atom(), String.t()} => atom()}
  def severities(modules, analyses) do
    {:ok, %Argus.Findings{degraded: []} = r} = Memo.run_analyses(modules, analyses: analyses)

    Map.new(r.findings, fn f ->
      {mod, fun, _} = f.mfa
      name = mod |> inspect() |> String.replace_prefix("Argus.Test.Soundness.", "")
      {{name, fun, f.title}, f.severity}
    end)
  end

  @doc "The highest severity of the findings whose key matches, or `nil`."
  @spec severity(map(), String.t(), atom(), String.t()) :: atom() | nil
  def severity(map, mod, fun, title) do
    map
    |> Enum.filter(fn {{m, f, t}, _} -> m == mod and f == fun and t =~ title end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.max_by(&rank/1, fn -> nil end)
  end

  defp rank(:error), do: 2
  defp rank(:warning), do: 1
  defp rank(:info), do: 0

  @doc "The modules compiled from a fixture file under test/fixtures/soundness."
  @spec modules(String.t()) :: [module()]
  def modules(file) do
    {:ok, mods} = :application.get_key(:argus_beam, :modules)

    mods
    |> Enum.filter(fn m ->
      source = m.module_info(:compile)[:source] |> to_string()
      String.ends_with?(source, "test/fixtures/soundness/" <> file)
    end)
    |> Enum.sort()
  end

  @doc "A relation's rows for `analysis` over `modules`."
  @spec rows([module()], atom(), String.t()) :: [[String.t()]]
  def rows(modules, analysis, relation) do
    {:ok, results} = Memo.analyze(modules, analysis)
    Map.get(results, relation, [])
  end
end
