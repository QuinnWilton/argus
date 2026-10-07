defmodule Argus.Test.BatchProperty do
  @moduledoc """
  A property over generated code whose cases are solved together, once
  per run, rather than once each.

  Most of a small solve is fixed cost: an engine's start on the program,
  and the compiling and extracting of each module. So `check_cases/2`
  draws `count` cases from the generator, each from a seed of its own
  (`StreamData.seeded/2`, the seeds picked under the test's ExUnit
  seed). It writes them all as functions of one module (`source`), each
  case one function, solves that module once, and asserts each case
  over the rows that name its function (`assert`).

  A case's rows are its answer alone only while the cases cannot see
  each other: no case may call another's function, or meet it through
  a name they share, such as a registered process, a table one writes
  and another reads, or a message one sends and another receives. A row
  naming two cases' functions fails the check, as such a meeting.
  `ARGUS_VERIFY_BATCH=1` checks the rest: each case is also solved in a
  module of its own, and its rows must be the batch's, relation by
  relation. Run a property with it after changing its generator or a
  rule its cases meet.

  A case wrong in the batch is checked again alone, as a property of its
  own that starts from that case's seed. StreamData shrinks that one
  case, solving each smaller case alone, and reports the smallest one
  still wrong. A case wrong in the batch but right alone fails too: the
  batch's cases saw each other.
  """

  use ExUnitProperties

  alias Argus.Test.Memo

  @seeds 0..(2 ** 32 - 1)

  # A case's function, as a row names it: `Mod:case_3/2`, or a fun in
  # it, `Mod:-case_3/2-fun-0-/1`.
  @case_function ~r/:-?(case_\d+)\//

  @typedoc """
  Writes one module holding each case as a function of the given name
  (`case_<n>`), and nothing that calls one case's function from
  another's.
  """
  @type source :: ([{String.t(), term()}] -> String.t())

  @typedoc "Raises an `ExUnit.AssertionError` when a case's rows are wrong for it."
  @type assertion :: (term(), Argus.Analysis.result() -> term())

  @typedoc "Options for `check_cases/2`."
  @type option ::
          {:analysis, atom()}
          | {:count, pos_integer()}
          | {:source, source()}
          | {:assert, assertion()}

  @doc """
  Checks `count` cases of `generator` in one solve of `analysis`, and
  shrinks a wrong one alone.
  """
  @spec check_cases(StreamData.t(term()), [option()]) :: :ok
  def check_cases(generator, opts) do
    analysis = Keyword.fetch!(opts, :analysis)
    count = Keyword.fetch!(opts, :count)
    source = Keyword.fetch!(opts, :source)
    assert = Keyword.fetch!(opts, :assert)

    seeds = ExUnitProperties.pick(list_of(integer(@seeds), length: count))

    cases =
      seeds
      |> Enum.with_index()
      |> Enum.map(fn {seed, i} -> {"case_#{i}", seed, generator |> from(seed) |> Enum.at(0)} end)

    batch = solve(analysis, source.(for {name, _seed, c} <- cases, do: {name, c}))

    if System.get_env("ARGUS_VERIFY_BATCH") in ["1", "true"] do
      for {name, _seed, c} <- cases, do: verify!(analysis, source, name, c, batch)
    end

    wrong =
      Enum.find_value(cases, fn {name, seed, c} ->
        try do
          assert.(c, Map.get(batch.slices, name, %{}))
          nil
        rescue
          error in ExUnit.AssertionError -> {seed, error}
        end
      end)

    case wrong do
      nil -> :ok
      {seed, error} -> shrink_alone!(generator, seed, error, analysis, source, assert)
    end
  end

  # The case of `seed`, the same however large the run's generation
  # size, so the batch and the property shrinking it alone start from
  # one value.
  defp from(generator, seed), do: generator |> StreamData.seeded(seed) |> resize(1)

  defp shrink_alone!(generator, seed, batch_error, analysis, source, assert) do
    check all(c <- from(generator, seed), max_runs: 1) do
      assert.(c, alone(analysis, source, "case_0", c))
    end

    raise ExUnit.AssertionError,
      message:
        "a case is wrong in the batch but right solved alone, so the batch's " <>
          "cases see each other (seed #{seed}):\n" <> Exception.message(batch_error)
  end

  # A case solved in a module of its own: its rows.
  defp alone(analysis, source, name, c) do
    analysis |> solve(source.([{name, c}])) |> Map.fetch!(:slices) |> Map.get(name, %{})
  end

  defp verify!(analysis, source, name, c, batch) do
    alone = analysis |> solve(source.([{name, c}])) |> anonymous(name)
    batched = anonymous(batch, name)

    if alone != batched do
      diff =
        for relation <- Enum.uniq(Map.keys(alone) ++ Map.keys(batched)),
            a = Map.get(alone, relation, []),
            b = Map.get(batched, relation, []),
            a != b,
            do: {relation, only_alone: a -- b, only_in_batch: b -- a}

      raise "#{name} solved alone disagrees with its rows in the batch: " <>
              inspect(diff, pretty: true, limit: :infinity) <> "\n" <> source.([{name, c}])
    end
  end

  # A case's rows with its module's name left out, to compare across
  # modules.
  defp anonymous(%{module: module, slices: slices}, name) do
    for {relation, rows} <- Map.get(slices, name, %{}), into: %{} do
      {relation,
       rows
       |> Enum.map(fn row -> Enum.map(row, &String.replace(&1, module, "<module>")) end)
       |> Enum.sort()}
    end
  end

  # One module's solve, and its rows by the case function each names.
  defp solve(analysis, source) do
    # Generated code calls deprecated and odd functions on purpose: its
    # compiler warnings are noise here.
    {beams, _warnings} =
      ExUnit.CaptureIO.with_io(:stderr, fn -> Memo.compile_beams(source) end)

    [beam] = beams
    {:ok, results} = Memo.analyze(beams, analysis)
    module = beam |> Path.basename(".beam") |> String.replace_prefix("Elixir.", "")
    %{module: module, slices: slices(results)}
  end

  defp slices(results) do
    for {relation, rows} <- results, row <- rows, reduce: %{} do
      acc ->
        case owners(row) do
          [] ->
            acc

          [name] ->
            Map.update(acc, name, %{relation => [row]}, fn slice ->
              Map.update(slice, relation, [row], &[row | &1])
            end)

          names ->
            raise ExUnit.AssertionError,
              message:
                "a #{relation} row names #{Enum.join(names, " and ")}, so the batch's " <>
                  "cases see each other: #{inspect(row)}"
        end
    end
  end

  defp owners(row) do
    for column <- row,
        [_, name] <- Regex.scan(@case_function, column),
        uniq: true,
        do: name
  end
end
