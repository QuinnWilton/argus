defmodule Argus.Test.Batch do
  @moduledoc """
  One solve of an analysis over several fixture sets, read back one set
  at a time as if each had been solved alone.

  A test module whose tests each solve their own small set pays the
  solver's start-up once per test; most of a races solve is Souffle
  compiling the program. `solve/2` in `setup_all` solves the union once,
  and `analyze/2` hands a test the rows its own set accounts for: a row
  belongs to a set when every fixture module of the batch it names is
  in the set, and it names at least one.

  That is `Argus.analyze(set, analysis)`'s answer only while the sets do
  not see each other: a whole-program rule can join a row of one
  fixture to another's (a caller in one set, a table writer in another)
  or read a fact no set owns. So the sets of a batch are disjoint — a
  test whose set shares a module with another's is about what the
  modules do together, and solves its set on its own — and
  `ARGUS_VERIFY_BATCH=1` checks the rest: each `analyze/2` also solves
  its set alone and fails unless the two agree, relation by relation.
  Run a batched module with it after adding a set or changing a rule
  its fixtures meet; a set that disagrees is solved on its own too.

  Both solves go through the suite's store (`Argus.Test.Memo.store/0`),
  so a run after an edit solves again only what the edit invalidated.
  """

  @enforce_keys [:analysis, :modules, :owner, :result]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          analysis: atom(),
          modules: [module()],
          owner: Regex.t(),
          result: {:ok, map()} | {:error, term()}
        }

  @doc "Solves `analysis` once over every module of `sets`."
  @spec solve(atom(), [[module()]]) :: t()
  def solve(analysis, sets) when is_atom(analysis) and is_list(sets) do
    modules = sets |> List.flatten() |> Enum.uniq()

    %__MODULE__{
      analysis: analysis,
      modules: modules,
      owner: owner_regex(modules),
      result: Argus.analyze(modules, analysis, cache: Argus.Test.Memo.store())
    }
  end

  @doc """
  What `Argus.analyze(set, analysis)` returns, read from the batch's
  solve: each relation's rows that `set` accounts for. Under
  `ARGUS_VERIFY_BATCH` the set is also solved alone and must agree.
  """
  @spec analyze(t(), [module()]) :: {:ok, map()} | {:error, term()}
  def analyze(%__MODULE__{} = batch, set) when is_list(set) do
    missing = set -- batch.modules

    if missing != [] do
      raise ArgumentError, "#{inspect(missing)} are not in the batch; add their set to solve/2"
    end

    sliced = slice(batch, set)
    if System.get_env("ARGUS_VERIFY_BATCH") in ["1", "true"], do: verify!(batch, set, sliced)
    sliced
  end

  defp slice(%{result: {:ok, results}} = batch, set) do
    names = MapSet.new(set, &name/1)

    {:ok,
     Map.new(results, fn {relation, rows} ->
       {relation, Enum.filter(rows, &owned?(&1, batch.owner, names))}
     end)}
  end

  defp slice(%{result: error}, _set), do: error

  defp owned?(row, owner, names) do
    named =
      for column <- row,
          [_, name] <- Regex.scan(owner, column),
          uniq: true,
          do: name

    named != [] and Enum.all?(named, &MapSet.member?(names, &1))
  end

  defp verify!(batch, set, sliced) do
    alone = Argus.analyze(set, batch.analysis, cache: Argus.Test.Memo.store())

    case {normalize(alone), normalize(sliced)} do
      {same, same} ->
        :ok

      {%{} = alone, %{} = sliced} ->
        diff =
          for relation <- Enum.uniq(Map.keys(alone) ++ Map.keys(sliced)),
              a = Map.get(alone, relation, []),
              s = Map.get(sliced, relation, []),
              a != s,
              do: {relation, only_alone: a -- s, only_in_batch: s -- a}

        raise "#{inspect(set)} solved alone disagrees with its slice of the " <>
                "#{batch.analysis} batch: #{inspect(diff, pretty: true, limit: :infinity)}"

      {alone, sliced} ->
        raise "#{inspect(set)}: alone #{inspect(alone)}, in the batch #{inspect(sliced)}"
    end
  end

  defp normalize({:ok, results}) do
    for {relation, rows} <- results, rows != [], into: %{}, do: {relation, Enum.sort(rows)}
  end

  defp normalize(error), do: error

  # A module as the facts spell it, delimited: not a prefix of a longer
  # name, nor the tail of one (`Mod:fun/1` and `Mod#3` name `Mod`;
  # `Mod.Sub` does not).
  defp owner_regex(modules) do
    alternatives =
      modules
      |> Enum.map(&name/1)
      |> Enum.sort_by(&(-byte_size(&1)))
      |> Enum.map_join("|", &Regex.escape/1)

    Regex.compile!("(?<![A-Za-z0-9_.])(#{alternatives})(?![A-Za-z0-9_.])")
  end

  defp name(module) do
    case Atom.to_string(module) do
      "Elixir." <> _ -> inspect(module)
      erlang -> erlang
    end
  end
end
