defmodule Argus.FindingsTest do
  # Sync on purpose: the no-souffle test masks PATH for the whole VM, so
  # it must not overlap with concurrently running souffle-backed tests.
  use ExUnit.Case

  alias Argus.Findings
  alias Argus.InstrId
  alias Argus.Souffle
  alias Argus.Test.Fixtures

  doctest Argus.Findings

  @finding_keys [:analysis, :severity, :title, :detail, :module, :mfa, :instr, :related]
  @severities [:error, :warning, :info]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # Every finding must have exactly the documented shape — Phase B
  # consumers (lowdown's analysis panel) pattern match on these keys.
  defp assert_finding_shape(finding) do
    assert Enum.sort(Map.keys(finding)) == Enum.sort(@finding_keys)
    assert is_atom(finding.analysis)
    assert finding.severity in @severities
    assert is_binary(finding.title) and finding.title != ""
    assert is_binary(finding.detail) and finding.detail != ""
    assert is_nil(finding.module) or is_atom(finding.module)

    case finding.mfa do
      nil -> :ok
      {m, f, a} -> assert is_atom(m) and is_atom(f) and is_integer(a)
    end

    assert is_nil(finding.instr) or match?(%InstrId{}, finding.instr)
    assert is_list(finding.related)

    Enum.each(finding.related, fn related ->
      assert Enum.sort(Map.keys(related)) == Enum.sort([:label, :module, :mfa, :instr])
      assert is_binary(related.label)
    end)
  end

  describe "run/2 shape and anchors" do
    test "unlinked_spawn findings carry instruction anchors" do
      skip_without_souffle()

      assert {:ok, %Findings{} = result} =
               Argus.run_analyses([Fixtures.UnlinkedSpawner], analyses: [:unlinked_spawn])

      assert [finding] = result.findings
      assert_finding_shape(finding)

      assert finding.analysis == :unlinked_spawn
      assert finding.severity == :warning
      assert finding.module == Fixtures.UnlinkedSpawner
      assert finding.mfa == {Fixtures.UnlinkedSpawner, :spawn_unlinked, 0}
      assert %InstrId{func: "spawn_unlinked", arity: 0, idx: idx} = finding.instr
      assert is_integer(idx) and idx >= 0

      assert [%{analysis: :unlinked_spawn, duration_ms: ms, finding_count: 1}] = result.ran
      assert is_integer(ms) and ms >= 0
      assert result.degraded == []
    end

    test "supervision findings anchor at the tree definition with witness evidence" do
      skip_without_souffle()

      modules = [
        Fixtures.DeadlockOrderSupervisor,
        Fixtures.SyncInitServer,
        Fixtures.WorkerA,
        Fixtures.WorkerB
      ]

      assert {:ok, result} = Argus.run_analyses(modules, analyses: [:one_for_one_coupling])

      assert result.findings != []
      Enum.each(result.findings, &assert_finding_shape/1)

      coupled = Enum.filter(result.findings, &(&1.title =~ "Coupled children"))
      assert coupled != []

      for finding <- coupled do
        assert finding.severity == :warning

        # The defect is the supervisor's composition, so the primary
        # anchor is the tree definition — instruction-precise, inside the
        # supervisor's init/1.
        assert finding.module == Fixtures.DeadlockOrderSupervisor
        assert %InstrId{func: "init", arity: 1} = finding.instr

        # The coupling call is labelled evidence in the depending child.
        labels = Enum.map(finding.related, & &1.label)
        assert "coupling call" in labels
        assert "called sibling" in labels

        witness = Enum.find(finding.related, &(&1.label == "coupling call"))
        assert witness.module == Fixtures.SyncInitServer
        assert {Fixtures.SyncInitServer, _func, _arity} = witness.mfa
      end
    end

    test "ets findings span severities with module anchors where rows allow" do
      skip_without_souffle()

      modules = [
        Fixtures.EtsOwner,
        Fixtures.EtsReader,
        Fixtures.EtsWriter,
        Fixtures.EtsUnnamed,
        Fixtures.EtsWellConfigured,
        Fixtures.EtsParamTable
      ]

      assert {:ok, result} = Argus.run_analyses(modules, analyses: [:ets])

      Enum.each(result.findings, &assert_finding_shape/1)

      unprotected = Enum.filter(result.findings, &(&1.title =~ "dies with its owner"))
      assert Enum.any?(unprotected, &(&1.module == Fixtures.EtsOwner))
      assert Enum.all?(unprotected, &(&1.severity == :warning))

      unnamed = Enum.filter(result.findings, &(&1.title =~ "Unnamed table"))

      assert [%{severity: :info, module: Fixtures.EtsUnnamed}] =
               Enum.map(unnamed, &Map.take(&1, [:severity, :module]))
    end

    test "name-only ets relations have honestly-nil anchors" do
      # No fixture currently triggers the concurrency hints, so pin the
      # builder directly: a row with no module gets no invented anchor.
      finding = Argus.Analyses.Ets.finding(:ets_missing_read_concurrency, [":t"])
      assert %{severity: :info, module: nil, mfa: nil, instr: nil} = finding
      assert finding.detail =~ "read_concurrency"
    end

    test "atom_safety findings carry instruction anchors and security severities" do
      skip_without_souffle()

      modules = [
        Fixtures.UnsafeAtomCreation,
        Fixtures.UnsafeDeserialization,
        Fixtures.CodeExecution,
        Fixtures.SafeModule
      ]

      assert {:ok, result} = Argus.run_analyses(modules, analyses: [:atom_safety])

      Enum.each(result.findings, &assert_finding_shape/1)
      assert result.findings != []

      # Every row anchors at the offending call instruction, which also
      # yields the full mfa.
      assert Enum.all?(result.findings, &match?(%InstrId{}, &1.instr))
      assert Enum.all?(result.findings, &match?({_m, _f, _a}, &1.mfa))

      deser = Enum.filter(result.findings, &(&1.title =~ "binary_to_term"))
      assert deser != []
      assert Enum.all?(deser, &(&1.severity == :error))
      assert Enum.any?(deser, &(elem(&1.mfa, 0) == Fixtures.UnsafeDeserialization))

      exhaustion = Enum.filter(result.findings, &(&1.title =~ "atom creation"))
      assert exhaustion != []
      assert Enum.all?(exhaustion, &(&1.severity == :warning))
    end

    test "call_cycle findings rank the cycle as error with path evidence as info" do
      skip_without_souffle()

      modules = [Fixtures.CycleServerA, Fixtures.CycleServerB]

      assert {:ok, result} = Argus.run_analyses(modules, analyses: [:call_cycle])

      Enum.each(result.findings, &assert_finding_shape/1)

      cycles = Enum.filter(result.findings, &(&1.severity == :error))
      assert cycles != []
      assert Enum.any?(cycles, &(&1.module in modules))
      assert Enum.any?(cycles, fn f -> Enum.any?(f.related, &(&1.label == "return path")) end)

      paths = Enum.filter(result.findings, &(&1.severity == :info))
      assert paths != []

      # Findings sort by severity: every error precedes every info.
      severity_sequence = Enum.map(result.findings, & &1.severity)
      assert severity_sequence == Enum.sort_by(severity_sequence, &(&1 != :error))
    end

    test ":all runs every builtin analysis except coverage" do
      skip_without_souffle()

      assert {:ok, result} = Argus.run_analyses([Fixtures.UnlinkedSpawner])

      ran_names = Enum.map(result.ran, & &1.analysis) |> Enum.sort()
      expected = Argus.Analysis.builtin_analyses() |> List.delete(:coverage) |> Enum.sort()

      assert ran_names == expected
      assert result.degraded == []
      Enum.each(result.findings, &assert_finding_shape/1)
    end
  end

  describe "run/2 degradation" do
    test "unknown analysis name is an error" do
      assert {:error, {:unknown_analysis, :nonexistent}} =
               Argus.run_analyses([:lists], analyses: [:nonexistent])
    end

    test "invalid analyses option is an error" do
      assert {:error, {:invalid_analyses, :some}} =
               Argus.run_analyses([:lists], analyses: :some)
    end

    test "empty analysis selection runs nothing" do
      assert {:ok, %Findings{findings: [], ran: [], degraded: []}} =
               Argus.run_analyses([:lists], analyses: [])
    end

    test "missing souffle is an explicit error, not a crash" do
      original_path = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", original_path) end)

      System.put_env("PATH", "/nonexistent_souffle_free_dir")
      refute Souffle.available?()

      assert {:error, :souffle_not_found} = Argus.run_analyses([:lists])
    end

    test "a failing analysis degrades with a note while the result still returns" do
      skip_without_souffle()

      assert {:ok, result} =
               Argus.run_analyses([Fixtures.UnlinkedSpawner],
                 analyses: [:unlinked_spawn],
                 souffle_timeout: 1
               )

      assert result.findings == []
      assert result.ran == []

      assert [%{analysis: :unlinked_spawn, reason: :souffle_timeout, detail: detail}] =
               result.degraded

      assert detail =~ "timed out"
    end

    test "extraction failure is a whole-call error" do
      skip_without_souffle()

      assert {:error, {:not_found, :fake_module_xyz}} =
               Argus.run_analyses([:fake_module_xyz], analyses: [:unlinked_spawn])
    end
  end

  describe "dedupe_rows/2" do
    @keyed_relation %{
      name: :coupled,
      fields: [
        {:sup, :symbol, "supervisor"},
        {:caller, :symbol, "caller"},
        {:witness, :func_id, "witnessing call site"}
      ],
      key: [:sup, :caller],
      doc: "test relation"
    }

    test "keeps one deterministic representative per key" do
      rows = [
        ["Sup", "Queue", "Queue:handle_call/3"],
        ["Sup", "Queue", "Queue:handle_cast/2"],
        ["Sup", "Sonar", "Sonar:init/1"]
      ]

      assert Findings.dedupe_rows(@keyed_relation, rows) == [
               ["Sup", "Queue", "Queue:handle_call/3"],
               ["Sup", "Sonar", "Sonar:init/1"]
             ]

      # Row order must not affect the outcome.
      assert Findings.dedupe_rows(@keyed_relation, Enum.reverse(rows)) ==
               Findings.dedupe_rows(@keyed_relation, rows)
    end

    test "relations without a key pass through unchanged" do
      relation = Map.delete(@keyed_relation, :key)
      rows = [["Sup", "Queue", "a"], ["Sup", "Queue", "b"]]
      assert Findings.dedupe_rows(relation, rows) == rows
    end

    test "raises on a key field the relation does not declare" do
      relation = %{@keyed_relation | key: [:nonexistent]}

      assert_raise ArgumentError, fn ->
        Findings.dedupe_rows(relation, [["Sup", "Queue", "a"]])
      end
    end
  end

  describe "anchor parsing" do
    test "module_atom round-trips inspect renderings" do
      assert Findings.module_atom("Argus.Findings") == Argus.Findings
      assert Findings.module_atom(":lists") == :lists
      assert Findings.module_atom(":\"weird name\"") == :"weird name"
      assert Findings.module_atom("dynamic") == nil
      assert Findings.module_atom("not a module") == nil
      assert Findings.module_atom("") == nil
    end

    test "at_func parses function IDs into mfa anchors" do
      assert %{module: :lists, mfa: {:lists, :map, 2}, instr: nil} =
               Findings.at_func(":lists:map/2")

      assert %{module: Argus.Findings, mfa: {Argus.Findings, :run, 2}, instr: nil} =
               Findings.at_func("Argus.Findings:run/2")

      # Compiler-generated closure names parse right-anchored.
      assert %{mfa: {Argus.Findings, :"-run/2-fun-0-", 3}} =
               Findings.at_func("Argus.Findings:-run/2-fun-0-/3")

      assert %{module: nil, mfa: nil, instr: nil} = Findings.at_func("dynamic")
    end

    test "at_instr parses instruction IDs into full anchors" do
      assert %{module: :lists, mfa: {:lists, :map, 2}, instr: %InstrId{idx: 7}} =
               Findings.at_instr(":lists:map/2#7")

      assert %{module: nil, mfa: nil, instr: nil} = Findings.at_instr("garbage")
    end
  end
end
