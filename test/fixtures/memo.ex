defmodule Argus.Test.Memo do
  @moduledoc """
  `Argus.analyze/3` and `Argus.run_analyses/2`, each computed once per
  test run for the same modules, analysis and options: several test
  modules solve the same fixture set, and a solve's answer is a term,
  so every caller after the first reads the one the first computed.

  An answer is immutable: sharing it keeps tests independent, which a
  shared facts directory would not. Only answers are kept (`{:ok, _}`),
  and a call with options is always made afresh: an option is how a
  test asks for a solver, a deadline or a facts directory of its own.

  The table is `test_helper.exs`'s, for the length of the run; without
  it every call is made.
  """

  @table __MODULE__

  @doc "Creates the run's table; `test_helper.exs` calls it once."
  @spec start() :: :ok
  def start do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  @doc "`Argus.analyze(modules, analysis)`, once per run."
  @spec analyze([module() | String.t()], Argus.Analysis.analysis(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def analyze(modules, analysis, opts \\ []) do
    once({:analyze, modules, analysis}, opts, fn -> Argus.analyze(modules, analysis, opts) end)
  end

  @doc "`Argus.run_analyses(modules, opts)`, once per run for `analyses:` alone."
  @spec run_analyses([module() | String.t()], keyword()) ::
          {:ok, Argus.Findings.t()} | {:error, term()}
  def run_analyses(modules, opts \\ []) do
    {analyses, rest} = Keyword.pop(opts, :analyses, :all)
    once({:run_analyses, modules, analyses}, rest, fn -> Argus.run_analyses(modules, opts) end)
  end

  defp once(key, [], compute) do
    case lookup(key) do
      {:ok, answer} ->
        answer

      :none ->
        answer = compute.()
        keep(key, answer)
        answer
    end
  end

  defp once(_key, _opts, compute), do: compute.()

  defp lookup(key) do
    case :ets.whereis(@table) do
      :undefined ->
        :none

      _ ->
        case :ets.lookup(@table, key) do
          [{^key, answer}] -> {:ok, answer}
          [] -> :none
        end
    end
  end

  defp keep(key, {:ok, _} = answer) do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {key, answer})
  end

  defp keep(_key, _error), do: :ok
end
