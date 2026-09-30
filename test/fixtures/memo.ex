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

  Across runs, every call goes through the suite's blob store
  (`Argus.Graph.store/0`, `_build/test/argus/store`): a fixture set's
  facts are extracted only for the producers an edit invalidated, and a
  solve only when what it reads changed. These are the tests of what a rule finds over a
  fixture — a function of the fixture's beams, the extractors' code,
  the rules and the solver, every one of them in the keys. A test of
  extraction or solving itself calls the pipeline or the solver
  directly and is never short-circuited; `ARGUS_NO_CACHE=1` runs the
  whole suite with every store off.

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

  @doc """
  An analysis's rules solved over hand-built facts (`Argus.Pipeline.write_facts/2`
  into a directory of the call's own, removed after).
  """
  @spec run_rules(map(), atom()) :: {:ok, map()} | {:error, term()}
  def run_rules(facts, analysis) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "argus_rules_#{:os.getpid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    try do
      :ok = Argus.Pipeline.write_facts(facts, dir)
      Argus.Analysis.run_rules(dir, analysis)
    after
      File.rm_rf(dir)
    end
  end

  @doc """
  Beams of the modules `source` defines, written where a path names
  them: under a directory named by the source's digest (and the
  compiler's), so the same source is the same beams at the same paths
  in every run — what the
  suite's store keys a fixture set's facts on. Written under a scratch
  name and renamed, so a test beside this one compiling the same source
  never reads half a file.
  """
  @spec compile_beams(String.t()) :: [Path.t()]
  def compile_beams(source) do
    compiler = System.version() <> System.otp_release()

    digest =
      :crypto.hash(:sha256, [compiler, source])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    dir = Path.join(System.tmp_dir!(), "argus_beams_#{digest}")
    File.mkdir_p!(dir)

    for {mod, beam} <- Code.compile_string(source) do
      path = Path.join(dir, "#{mod}.beam")

      unless File.exists?(path) do
        scratch = "#{path}.#{:os.getpid()}.#{System.unique_integer([:positive])}"
        File.write!(scratch, beam)
        File.rename!(scratch, path)
      end

      path
    end
  end

  @doc """
  `Argus.analyze(modules, analysis)`, once per run, through the suite's
  blob store (`Argus.Graph.store/0`, `_build/test/argus/store`).
  """
  @spec analyze([module() | String.t()], Argus.Analysis.analysis(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def analyze(modules, analysis, opts \\ []) do
    once({:analyze, modules, analysis}, opts, fn -> Argus.analyze(modules, analysis, opts) end)
  end

  @doc """
  `Argus.run_analyses(modules, opts)`, once per run for `analyses:`
  alone, through the suite's blob store.
  """
  @spec run_analyses([module() | String.t()], keyword()) ::
          {:ok, Argus.Findings.t()} | {:error, term()}
  def run_analyses(modules, opts \\ []) do
    {analyses, rest} = Keyword.pop(opts, :analyses, :all)

    once({:run_analyses, modules, analyses}, rest, fn ->
      Argus.run_analyses(modules, [analyses: analyses] ++ rest)
    end)
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
