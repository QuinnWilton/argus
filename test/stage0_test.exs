defmodule Argus.Stage0Test do
  @moduledoc """
  The stage-0 stratification contract.

  `call_edge` is derived once by `stage0.dl` and read by the analyses as
  facts, instead of being re-derived inside every solve. The point is not
  only to avoid recomputing one fixpoint per analysis — it is to keep the
  layer-1 bytecode relations out of each analysis's input set, so an
  incremental consumer can tell that editing a function body cannot have
  changed a supervision finding.

  These tests pin that property. If someone reintroduces a `cfg.dl`
  include into `clientlib/imports.dl`, or derives `call_edge` locally
  again, the coupling silently returns and every analysis starts
  re-solving on every edit. The assertions below fail loudly instead.
  """

  use ExUnit.Case

  alias Argus.Analysis
  alias Argus.Pipeline
  alias Argus.Souffle

  @moduletag :tmp_dir

  # Relations that churn whenever any function body changes: instruction
  # indices shift, control flow is renumbered. An analysis reading these
  # can never cut off on an edit.
  @volatile_cfg_relations ~w(branch jump next label_at select_branch closure_def local_call bif_call)

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  describe "derive_stage0/2" do
    test "writes call_edge.facts into the facts directory", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Pipeline.run([Argus.Test.Fixtures.MyGenServer], facts_dir)

      refute File.exists?(Path.join(facts_dir, "call_edge.facts"))
      assert :ok = Analysis.derive_stage0(facts_dir)

      staged = Path.join(facts_dir, "call_edge.facts")
      assert File.exists?(staged)
      assert File.read!(staged) != ""
    end

    test "is idempotent — re-deriving reproduces the same content", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Pipeline.run([Argus.Test.Fixtures.MyGenServer], facts_dir)

      assert :ok = Analysis.derive_stage0(facts_dir)
      first = File.read!(Path.join(facts_dir, "call_edge.facts"))

      assert :ok = Analysis.derive_stage0(facts_dir)
      assert File.read!(Path.join(facts_dir, "call_edge.facts")) == first
    end

    test "extract_facts/3 stages it, so run_rules never has to", %{tmp_dir: _tmp_dir} do
      skip_without_souffle()

      assert {:ok, facts_dir} =
               Analysis.extract_facts([Argus.Test.Fixtures.MyGenServer], [:supervision], [])

      on_exit(fn -> File.rm_rf(Path.dirname(facts_dir)) end)

      assert File.exists?(Path.join(facts_dir, "call_edge.facts"))
    end

    test "run_rules/3 derives it on demand for hand-built fact directories",
         %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      {:ok, _} = Pipeline.run([Argus.Test.Fixtures.MyGenServer], facts_dir)
      refute File.exists?(Path.join(facts_dir, "call_edge.facts"))

      assert {:ok, _results} = Analysis.run_rules(facts_dir, :supervision)
      assert File.exists?(Path.join(facts_dir, "call_edge.facts"))
    end
  end

  describe "input_relations/1" do
    test "reports the staged call graph, not its layer-1 ingredients" do
      skip_without_souffle()

      assert {:ok, relations} = Analysis.input_relations(:one_for_one_coupling)

      assert "call_edge" in relations,
             "analyses must read the staged call graph"

      refute "remote_call" in relations,
             "call_edge's ingredients belong to stage 0, not to the analysis"
    end

    test "the supervision family no longer reads volatile control-flow relations" do
      skip_without_souffle()

      # These reason about supervision structure. Nothing about a function
      # body's control flow can change their verdict, and after
      # stratification their input sets say so — which is exactly what
      # lets an incremental driver skip them on an ordinary edit.
      for analysis <- [:one_for_one_coupling, :supervision, :sync_call_in_init] do
        assert {:ok, relations} = Analysis.input_relations(analysis)

        leaked = Enum.filter(@volatile_cfg_relations, &(&1 in relations))

        assert leaked == [],
               "#{analysis} reads volatile control-flow relations #{inspect(leaked)}; " <>
                 "the stage-0 split exists to keep them out of its input set"

        refute "instruction" in relations,
               "#{analysis} reads `instruction`, which changes on any body edit"
      end
    end

    test "input sets are genuinely resolved, not uniformly narrow" do
      skip_without_souffle()

      # The guard above must not be vacuous. It used to be anchored on some
      # analysis still reading `instruction` — first unlinked_spawn, then
      # unsafe_task. Neither does now, so the anchor has to be something
      # else: that `input_relations/1` really discriminates between
      # analyses rather than returning something uniformly small.
      sets =
        for mod <- Analysis.builtin_analysis_modules() do
          {:ok, relations} = Analysis.input_relations(mod.name())
          {mod.name(), relations}
        end

      # Every analysis reads something, and they do not all read the same
      # thing — so a narrow set below is a real result about that analysis.
      assert Enum.all?(sets, fn {name, rels} -> rels != [] or flunk("#{name} reads nothing") end)
      assert sets |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 10

      # And the spread is real: the supervision family reads a lot, while
      # unlinked_spawn is down to the single relation it actually needs.
      assert {_, spawn_relations} = Enum.find(sets, &(elem(&1, 0) == :unlinked_spawn))
      assert spawn_relations == ["spawn_call"]

      {_, supervision_relations} = Enum.find(sets, &(elem(&1, 0) == :supervision))
      assert length(supervision_relations) > 8
    end

    test "unknown analyses error rather than returning an empty set" do
      assert {:error, {:unknown_analysis, :nope}} = Analysis.input_relations(:nope)
    end
  end
end
