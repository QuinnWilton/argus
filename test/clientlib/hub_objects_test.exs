defmodule Argus.Clientlib.HubObjectsTest do
  @moduledoc """
  The selective points-to stage (`priv/dl/points_to_selective.dl` over
  `clientlib/hub_objects.dl`): what the stage runs when the full one
  outgrows its budget (`Argus.Analysis.PointsToBudgetTest` has when it
  does). Over the PidFlow fixtures no object is a hub, so it must write
  what the full stage writes; its field-insensitive pass must reach
  every target the full stage does, since a hub object's targets are
  that pass's; and an object made a hub must keep its targets while
  every other object keeps exactly its own.
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.{Analysis, Pipeline}

  # The staged relations, each a `.facts` file both stages write.
  @staged Analysis.points_to_relations()

  setup_all do
    dir = Path.join(System.tmp_dir!(), "argus_hub_objects_#{System.unique_integer([:positive])}")
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

    full = solve(dir, facts_dir, "full", Analysis.points_to_rules_path())

    # The full stage's terms: what each variable points to.
    full_terms =
      program(dir, facts_dir, "full_terms", """
      .include "#{Analysis.points_to_rules_path()}"

      .output var_points_to
      """)

    selective = solve(dir, facts_dir, "selective", Analysis.points_to_selective_rules_path())

    # The selective stage with TargetA's instances made hub objects, and
    # its field-insensitive pass's own view of every use.
    forced =
      program(dir, facts_dir, "forced", """
      .include "#{Analysis.points_to_selective_rules_path()}"

      hub_object(p) :- stage_mode("selective"), instance(p, b), process_start(_, _, b, "server", m),
        m = "Argus.Test.Fixtures.PidFlow.TargetA".

      .output field_insensitive_process_use
      .output var_points_to
      """)

    %{
      dir: dir,
      facts_dir: facts_dir,
      full: full,
      full_terms: full_terms,
      selective: selective,
      forced: forced
    }
  end

  defp solve(dir, facts_dir, name, rules_path) do
    output_dir = Path.join(dir, name)
    File.mkdir_p!(output_dir)
    {:ok, results} = Argus.FlowLog.run(facts_dir, rules_path, output_dir: output_dir)
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

  test "no object of a small program is a hub, and the selective stage writes what the full one does",
       ctx do
    assert ctx.selective["hub_object"] == []
    assert ctx.full["points_to_mode"] == [["full"]]
    assert ctx.selective["points_to_mode"] == [["selective"]]

    for relation <- @staged, relation != "points_to_mode" do
      assert ctx.selective[relation] == ctx.full[relation], "#{relation} differs"
    end
  end

  test "the field-insensitive pass reaches every target the full stage does", ctx do
    field_insensitive = MapSet.new(ctx.forced["field_insensitive_process_use"])

    assert ctx.full["process_call"] != []

    for row <- ctx.full["process_call"] do
      assert row in field_insensitive, "the field-insensitive pass misses #{inspect(row)}"
    end
  end

  test "a kept start of a hub process is no term: the field-insensitive pass holds it", ctx do
    hubs = MapSet.new(ctx.forced["hub_object"], fn [p] -> p end)

    # The {:ok, pid} each kept start of a hub process answers.
    wrappers = for "start " <> c <- hubs, do: "result " <> c
    assert wrappers != []

    terms = fn results -> MapSet.new(results["var_points_to"], &List.last/1) end

    # A term the full stage follows...
    assert Enum.any?(wrappers, &MapSet.member?(terms.(ctx.full_terms), &1))
    # ...and, once its process is a hub, none: holding nothing exact, it
    # would only make every term it is put in one to follow.
    refute Enum.any?(wrappers, &MapSet.member?(terms.(ctx.forced), &1))
  end

  test "an object made a hub keeps its targets, and every other object keeps its own", ctx do
    hubs = MapSet.new(ctx.forced["hub_object"], fn [p] -> p end)
    assert MapSet.size(hubs) > 0

    split = fn rows -> Enum.split_with(rows, fn row -> List.last(row) in hubs end) end

    for relation <- ~w(process_call call_site_target) do
      {full_hubs, full_rest} = split.(ctx.full[relation])
      {forced_hubs, forced_rest} = split.(ctx.forced[relation])

      # Resolved as before where no hub process is involved...
      assert forced_rest == full_rest, "#{relation}: another object's rows moved"
      # ...and a hub's rows are a superset of its full ones.
      assert full_hubs != []
      assert MapSet.subset?(MapSet.new(full_hubs), MapSet.new(forced_hubs))
    end
  end
end
