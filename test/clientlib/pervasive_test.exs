defmodule Argus.Clientlib.PervasiveTest do
  @moduledoc """
  The bounded points-to stage (`priv/dl/points_to_bounded.dl` over
  `clientlib/pervasive.dl`): what the stage runs when the exact one
  outgrows its budget (`Argus.Analysis.PointsToBudgetTest` has when it
  does). Over the PidFlow fixtures no leaf is pervasive, so
  it must write what the exact stage writes; its coarse pass must reach
  every target the exact pass does, since a pervasive leaf's targets are
  that pass's; and a leaf made pervasive must keep its targets while
  every other leaf keeps exactly its own.
  """
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.{Analysis, Pipeline, Souffle}

  # The staged relations, each a `.facts` file both stages write.
  @staged Analysis.points_to_relations()

  setup_all do
    dir = Path.join(System.tmp_dir!(), "argus_pervasive_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    facts_dir = Path.join(dir, "facts")

    {:ok, modules} = :application.get_key(:argus_beam, :modules)

    fixtures =
      modules
      |> Enum.filter(
        &String.starts_with?(Atom.to_string(&1), "Elixir.Argus.Test.Fixtures.PidFlow.")
      )
      |> Enum.sort()

    {:ok, _} =
      Pipeline.run(fixtures, facts_dir,
        extractors: [
          Argus.Extractors.OTP,
          Argus.Extractors.ApiCalls,
          Argus.Extractors.CallbackTag,
          Argus.Extractors.ProcessRegistry,
          Argus.Extractors.Supervision,
          Argus.Extractors.GenStatem,
          Argus.Extractors.TermFlow,
          Argus.Extractors.CallArgs
        ]
      )

    :ok = Analysis.derive_stage0(facts_dir)

    exact = solve(dir, facts_dir, "exact", Analysis.points_to_rules_path())
    bounded = solve(dir, facts_dir, "bounded", Analysis.points_to_bounded_rules_path())

    # The bounded stage with the leaves TargetA's instances made
    # pervasive, and its coarse pass's own view of every use.
    forced =
      program(dir, facts_dir, "forced", """
      .include "#{Analysis.points_to_bounded_rules_path()}"

      pervasive(p) :- stage_mode("bounded"), instance(p, b), process_start(_, _, b, "server", m),
        m = "Argus.Test.Fixtures.PidFlow.TargetA".

      .output coarse_use
      """)

    %{
      dir: dir,
      facts_dir: facts_dir,
      exact: exact,
      bounded: bounded,
      forced: forced
    }
  end

  defp solve(dir, facts_dir, name, rules_path) do
    output_dir = Path.join(dir, name)
    File.mkdir_p!(output_dir)
    {:ok, results} = Souffle.run(facts_dir, rules_path, output_dir: output_dir)
    Map.merge(results, read_staged(output_dir))
  end

  defp program(dir, facts_dir, name, source) do
    rules_path = Path.join(dir, name <> ".dl")
    File.write!(rules_path, source)
    solve(dir, facts_dir, name, rules_path)
  end

  defp read_staged(dir) do
    Map.new(@staged, fn relation ->
      rows = dir |> Path.join(relation <> ".facts") |> File.read!() |> Argus.Tsv.decode()
      {relation, rows |> Enum.sort()}
    end)
  end

  test "no leaf of a small program is pervasive, and the bounded stage writes what the exact one does",
       ctx do
    assert ctx.bounded["pervasive"] == []
    assert ctx.exact["points_to_mode"] == [["exact"]]
    assert ctx.bounded["points_to_mode"] == [["bounded"]]

    for relation <- @staged, relation != "points_to_mode" do
      assert ctx.bounded[relation] == ctx.exact[relation], "#{relation} differs"
    end
  end

  test "the coarse pass reaches every target the exact pass does", ctx do
    coarse = MapSet.new(ctx.forced["coarse_use"])

    assert ctx.exact["process_call"] != []

    for row <- ctx.exact["process_call"] do
      assert row in coarse, "the coarse pass misses #{inspect(row)}"
    end
  end

  test "a leaf made pervasive keeps its targets, and every other leaf keeps its own", ctx do
    pervasive = MapSet.new(ctx.forced["pervasive"], fn [p] -> p end)
    assert MapSet.size(pervasive) > 0

    split = fn rows -> Enum.split_with(rows, fn row -> List.last(row) in pervasive end) end

    for relation <- ~w(process_call call_site_target) do
      {exact_pervasive, exact_rest} = split.(ctx.exact[relation])
      {forced_pervasive, forced_rest} = split.(ctx.forced[relation])

      # Resolved exactly, as before, where no pervasive process is involved...
      assert forced_rest == exact_rest, "#{relation}: another leaf's rows moved"
      # ...and a pervasive one's rows are a superset of its exact ones.
      assert exact_pervasive != []
      assert MapSet.subset?(MapSet.new(exact_pervasive), MapSet.new(forced_pervasive))
    end
  end
end
