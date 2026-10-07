defmodule Argus.FindingsTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Failure
  alias Argus.Analyses.Mailbox
  alias Argus.Findings
  alias Argus.InstrId
  alias Argus.Test.Fixtures
  alias Argus.Test.Memo

  doctest Argus.Findings

  @finding_keys [
    :analysis,
    :concern,
    :severity,
    :title,
    :detail,
    :module,
    :mfa,
    :instr,
    :at_label,
    :at_source,
    :to_instr,
    :to_block,
    :help,
    :related,
    :provenance,
    :confidence,
    # Where it is: nil from the batch backend, placed by the graph's
    # (`Argus.Located`).
    :file,
    :line,
    :end_line
  ]
  @severities [:error, :warning, :info]

  # Every finding must have exactly the documented shape — Phase B
  # consumers (lowdown's analysis panel) pattern match on these keys.
  defp assert_finding_shape(finding) do
    assert Enum.sort(Map.keys(finding)) == Enum.sort(@finding_keys)
    assert is_atom(finding.analysis)
    assert is_atom(finding.concern)
    assert finding.severity in @severities
    assert is_binary(finding.title) and finding.title != ""
    assert is_binary(finding.detail) and finding.detail != ""
    assert is_nil(finding.module) or is_atom(finding.module)

    case finding.mfa do
      nil -> :ok
      {m, f, a} -> assert is_atom(m) and is_atom(f) and is_integer(a)
    end

    assert is_nil(finding.instr) or match?(%InstrId{}, finding.instr)
    assert is_nil(finding.at_label) or is_binary(finding.at_label)
    assert is_list(finding.help)
    Enum.each(finding.help, &assert(is_binary(&1)))
    assert is_list(finding.related)

    Enum.each(finding.related, fn related ->
      assert Enum.sort(Map.keys(related)) ==
               Enum.sort([
                 :label,
                 :module,
                 :mfa,
                 :instr,
                 :to_instr,
                 :to_block,
                 :at_source,
                 :file,
                 :line,
                 :end_line
               ])

      assert is_binary(related.label)
    end)
  end

  describe "run/2 shape and anchors" do
    @describetag :flowlog

    test "unlinked_spawn findings carry instruction anchors" do
      assert {:ok, %Findings{} = result} =
               Memo.run_analyses([Fixtures.UnlinkedSpawner], analyses: [:failure])

      assert [finding] = result.findings
      assert_finding_shape(finding)

      assert finding.analysis == :failure
      assert finding.severity == :warning
      assert finding.module == Fixtures.UnlinkedSpawner
      assert finding.mfa == {Fixtures.UnlinkedSpawner, :spawn_unlinked, 0}
      assert %InstrId{func: "spawn_unlinked", arity: 0, idx: idx} = finding.instr
      assert is_integer(idx) and idx >= 0

      assert [%{analysis: :failure, duration_ms: ms, finding_count: 1}] = result.ran
      assert is_integer(ms) and ms >= 0
      assert result.degraded == []
    end

    test "supervision findings anchor at the tree definition with witness evidence" do
      # CastJoiner's init/1 subscribes to its sibling CastKeeper, which
      # keeps the subscriber in its state (test/fixtures/soundness/
      # coupling_soundness.ex).
      modules = [
        Fixtures.Restart.CastSup,
        Fixtures.Restart.CastKeeper,
        Fixtures.Restart.CastJoiner
      ]

      assert {:ok, result} = Memo.run_analyses(modules, analyses: [:coupling])

      assert result.findings != []
      Enum.each(result.findings, &assert_finding_shape/1)

      coupled = Enum.filter(result.findings, &(&1.title =~ "Coupled children"))
      assert coupled != []

      for finding <- coupled do
        assert finding.severity == :warning

        # The defect is the supervisor's composition, so the primary
        # anchor is the tree definition — instruction-precise, inside the
        # supervisor's init/1.
        assert finding.module == Fixtures.Restart.CastSup
        assert %InstrId{func: "init", arity: 1} = finding.instr

        # The registration is labelled evidence in the registering child,
        # and what keeps it in the sibling.
        labels = Enum.map(finding.related, & &1.label)
        assert "registers with the sibling here" in labels
        assert "kept here" in labels

        witness = Enum.find(finding.related, &(&1.label == "registers with the sibling here"))
        assert witness.module == Fixtures.Restart.CastJoiner
        assert {Fixtures.Restart.CastJoiner, :init, 1} = witness.mfa

        kept = Enum.find(finding.related, &(&1.label == "kept here"))
        assert kept.module == Fixtures.Restart.CastKeeper
      end
    end

    test "ets findings span severities with module anchors where rows allow" do
      modules = [
        Fixtures.EtsOwner,
        Fixtures.EtsReader,
        Fixtures.EtsWriter,
        Fixtures.EtsUnnamed,
        Fixtures.EtsWellConfigured,
        Fixtures.EtsParamTable
      ]

      assert {:ok, result} = Memo.run_analyses(modules, analyses: [:ets])

      Enum.each(result.findings, &assert_finding_shape/1)

      unprotected = Enum.filter(result.findings, &(&1.title =~ "dies with its owner"))
      assert Enum.any?(unprotected, &(&1.module == Fixtures.EtsOwner))
      assert Enum.all?(unprotected, &(&1.severity == :warning))

      unnamed = Enum.filter(result.findings, &(&1.title =~ "Unnamed table"))

      assert [%{severity: :info, module: Fixtures.EtsUnnamed}] =
               Enum.map(unnamed, &Map.take(&1, [:severity, :module]))
    end

    test "the concurrency hints anchor at the table's :ets.new" do
      {:ok, result} =
        Memo.run_analyses(
          [
            Fixtures.EtsSharedCounters,
            Fixtures.EtsSharedCountersClient,
            Fixtures.EtsSharedTuned,
            Fixtures.EtsSharedTunedClient
          ],
          analyses: [:ets]
        )

      for title <- [
            "Table without read_concurrency",
            "Table without write_concurrency",
            "ordered_set shared across modules"
          ] do
        assert [f] = Enum.filter(result.findings, &(&1.title == title)), title
        assert f.severity == :info
        assert f.module == Fixtures.EtsSharedCounters
        assert %{func: "init", arity: 1} = f.instr
      end
    end

    test "unsafe_input findings carry instruction anchors and security severities" do
      modules = [
        Fixtures.UnsafeAtomCreation,
        Fixtures.UnsafeDeserialization,
        Fixtures.CodeExecution,
        Fixtures.SafeModule
      ]

      assert {:ok, result} = Memo.run_analyses(modules, analyses: [:unsafe_input])

      Enum.each(result.findings, &assert_finding_shape/1)
      assert result.findings != []

      assert Enum.all?(
               result.findings,
               &(&1.analysis == :unsafe_input and &1.concern == :unsafe_input)
             )

      # Every row anchors at the offending call instruction, which also
      # yields the full mfa.
      assert Enum.all?(result.findings, &match?(%InstrId{}, &1.instr))
      assert Enum.all?(result.findings, &match?({_m, _f, _a}, &1.mfa))

      deser = Enum.filter(result.findings, &(&1.title =~ "binary_to_term"))
      assert deser != []
      assert Enum.any?(deser, &(elem(&1.mfa, 0) == Fixtures.UnsafeDeserialization))

      # No `:safe` is an error; `[:safe]` without a shape check only a
      # warning, since atoms are the one thing it does rule out.
      severity_by_function = Map.new(deser, &{elem(&1.mfa, 1), &1.severity})
      assert severity_by_function[:decode_unsafe] == :error
      assert severity_by_function[:decode_atoms_only] == :warning
      assert Enum.all?(deser, &(&1.severity in [:error, :warning]))

      exhaustion = Enum.filter(result.findings, &(&1.title =~ "atom creation"))
      assert exhaustion != []
      assert Enum.all?(exhaustion, &(&1.severity == :warning))
    end

    @tag flowlog: false
    test "a name argus retired is unknown" do
      assert {:error, {:unknown_analysis, :atom_safety}} =
               Memo.run_analyses([Fixtures.UnsafeAtomCreation],
                 analyses: [:atom_safety]
               )
    end

    test "a name asked for twice runs once" do
      assert {:ok, result} =
               Memo.run_analyses([Fixtures.UnsafeAtomCreation],
                 analyses: [:unsafe_input, :exposure, :unsafe_input]
               )

      assert Enum.map(result.ran, & &1.analysis) == [:unsafe_input, :exposure]
    end

    test "a named set selects its analyses" do
      assert {:ok, result} =
               Memo.run_analyses([Fixtures.UnsafeAtomCreation], analyses: :security)

      assert Enum.map(result.ran, & &1.analysis) == Argus.Analysis.set(:security) |> elem(1)
    end

    test "a call cycle is one error finding carrying its edges as related frames" do
      modules = [Fixtures.CycleServerA, Fixtures.CycleServerB]

      assert {:ok, result} = Memo.run_analyses(modules, analyses: [:blocking])

      Enum.each(result.findings, &assert_finding_shape/1)

      assert [cycle] = result.findings
      assert cycle.severity == :error
      assert cycle.module in modules
      assert Enum.any?(cycle.related, &(&1.label == "return path"))

      # The edges of the cycle are evidence, not findings of their own.
      edges = Enum.filter(cycle.related, &String.starts_with?(&1.label, "cycle edge "))
      assert length(edges) == 2
      assert Enum.all?(edges, &(&1.mfa != nil))
    end

    test ":all runs every builtin analysis except coverage" do
      assert {:ok, result} = Memo.run_analyses([Fixtures.UnlinkedSpawner])

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
               Memo.run_analyses([:lists], analyses: [:nonexistent])
    end

    test "invalid analyses option is an error" do
      assert {:error, {:invalid_analyses, :some}} =
               Memo.run_analyses([:lists], analyses: :some)
    end

    @tag :flowlog
    test "empty analysis selection runs nothing" do
      assert {:ok, %Findings{findings: [], ran: [], degraded: []}} =
               Memo.run_analyses([:lists], analyses: [])
    end

    # A store of its own: a solve another run kept would be read back
    # rather than run against the deadline.
    @tag :flowlog
    test "a failing analysis degrades with a note while the result still returns" do
      store = Path.join(System.tmp_dir!(), "argus-degrade-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(store) end)

      assert {:ok, result} =
               Memo.run_analyses([Fixtures.UnlinkedSpawner],
                 analyses: [:failure],
                 timeout: 1,
                 store: store
               )

      assert result.findings == []
      assert result.ran == []

      # Its own solve, or the points-to stage it reads, whichever the
      # engine reached first (a stage derived earlier in this VM is kept).
      assert [%{analysis: :failure, reason: reason, detail: detail}] = result.degraded
      assert reason in [:flowlog_timeout, {:points_to, :flowlog_timeout}]
      assert detail =~ "timed out" or detail =~ "did not finish within :timeout"
    end

    @tag :flowlog
    test "extraction failure is a whole-call error" do
      assert {:error, {:not_found, :fake_module_xyz}} =
               Memo.run_analyses([:fake_module_xyz], analyses: [:failure])
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

    test "a key chosen by kind needs no default: an unnamed kind keeps every column" do
      relation = %{
        name: :effect,
        fields: [{:mod, :symbol, "m"}, {:kind, :symbol, "k"}, {:api, :symbol, "a"}],
        key: {:kind, %{"connect" => [:mod], "recv" => [:kind, :api]}},
        doc: "test relation"
      }

      rows = [
        ["M", "connect", "a"],
        ["M", "connect", "b"],
        ["M", "recv", "r"],
        ["N", "recv", "r"],
        ["M", "other", "x"],
        ["M", "other", "y"]
      ]

      assert Findings.dedupe_rows(relation, rows) == [
               ["M", "connect", "a"],
               ["M", "other", "x"],
               ["M", "other", "y"],
               ["M", "recv", "r"]
             ]
    end

    test "relations without a key pass through unchanged" do
      relation = Map.delete(@keyed_relation, :key)
      rows = [["Sup", "Queue", "a"], ["Sup", "Queue", "b"]]
      assert Findings.dedupe_rows(relation, rows) == rows
    end

    test "evidence relations become related frames of the finding they join" do
      relation_rows = %{
        "sync_call_fan_in" => [["Target", "5"]],
        "bottleneck_caller" => [
          ["B", "Target", "B:call/0"],
          ["A", "Target", "A:call/0"],
          ["A", "Target", "A:other/0"],
          ["Z", "Other", "Z:call/0"]
        ]
      }

      assert [finding] = Findings.build(Argus.Analyses.Blocking, relation_rows)
      assert finding.title == "High synchronous fan-in"

      # One frame per caller module, in row order, only for this target.
      assert Enum.map(finding.related, & &1.label) == ["caller A", "caller B"]
      assert Enum.map(finding.related, & &1.mfa) == [{A, :call, 0}, {B, :call, 0}]
    end

    test "a custom analysis's evidence relations become its findings' frames" do
      relation_rows = %{
        "finding" => [["Foo"], ["Bar"]],
        "witness" => [["Foo", "Foo:g/0#1"], ["Foo", "Foo:h/0#2"], ["Bar", "Bar:g/0#3"]]
      }

      findings = Findings.build(__MODULE__.CustomEvidence, relation_rows)
      by_module = Map.new(findings, &{&1.module, &1})

      assert Enum.map(by_module[Foo].related, & &1.mfa) == [{Foo, :g, 0}, {Foo, :h, 0}]
      assert Enum.map(by_module[Bar].related, & &1.mfa) == [{Bar, :g, 0}]
    end

    test "build/2 ignores relations the analysis does not declare as outputs" do
      assert [finding] =
               Findings.build(__MODULE__.CustomEvidence, %{
                 "finding" => [["Foo"]],
                 "call_reachable" => [["Foo:f/0", "Foo:g/0"]]
               })

      assert finding.module == Foo
      assert finding.concern == :custom_evidence
    end

    test "a builder raising on one row costs that row, not the concern" do
      findings =
        Findings.build(__MODULE__.Fragile, %{
          "finding" => [["Foo"], ["boom"], ["Bar"]],
          "witness" => [["Foo", "Foo:g/0#1"], ["Foo", "boom"]]
        })

      assert [foo, boom, bar] = findings
      assert {foo.module, bar.module} == {Foo, Bar}
      assert boom.title == "Finding"
      assert boom.detail =~ "mod=boom"
      assert List.last(boom.help) =~ "could not render this finding row (no boom)"

      # The raising evidence row becomes a raw frame; its sibling renders.
      assert [%{label: "witness"}, %{label: raw}] = foo.related
      assert raw =~ "could not render this witness row"
    end

    test "two evidence relations joining one finding relation is an analysis bug" do
      assert_raise ArgumentError, ~r/:finding has two evidence relations/, fn ->
        Findings.build(__MODULE__.TwoEvidence, %{"finding" => [["Foo"]]})
      end
    end

    test "a key chosen by kind identifies each kind of row its own way" do
      relation = %{
        name: :merged,
        fields: [
          {:mod, :symbol, "module"},
          {:kind, :symbol, "kind"},
          {:api, :symbol, "call"},
          {:via, :symbol, "site"}
        ],
        key: {:kind, %{"unclear" => [:mod], default: [:mod, :api]}},
        doc: "test relation"
      }

      rows = [
        ["M", "unclear", "Lease.release/1", "f"],
        ["M", "unclear", "Session.close/1", "g"],
        ["M", "never_runs", "File.write/2", "f"],
        ["M", "never_runs", "File.write/2", "g"],
        ["M", "never_runs", "File.rm/1", "f"]
      ]

      # One unclear row per module; one never_runs row per api; the
      # kinds never collapse into each other.
      assert Findings.dedupe_rows(relation, rows) == [
               ["M", "never_runs", "File.rm/1", "f"],
               ["M", "never_runs", "File.write/2", "f"],
               ["M", "unclear", "Lease.release/1", "f"]
             ]
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

    test "module_atom refuses function IDs rather than inventing a module" do
      assert Findings.module_atom("Foo.Bar:baz/1") == nil
      assert Findings.module_atom(":lists:map/2") == nil
      assert Findings.module_atom("Foo.bar") == nil
      assert Findings.module_atom(":\"Elixir.Foo.bar\"") == :"Elixir.Foo.bar"
    end

    test "at_site_in_func anchors an unresolvable site at the row's function" do
      assert %{module: Foo.Bar, mfa: {Foo.Bar, :baz, 1}, instr: nil} =
               Findings.at_site_in_func("dynamic", "Foo.Bar:baz/1")

      assert %{module: :lists, mfa: {:lists, :map, 2}} =
               Findings.at_site_in_func("", ":lists:map/2")

      assert %{instr: %InstrId{idx: 4}} = Findings.at_site_in_func("Foo:g/0#4", "Foo.Bar:baz/1")
      assert %{module: Foo, mfa: nil} = Findings.at_site_in_func("", "dynamic", "Foo")
      assert %{module: nil, mfa: nil, instr: nil} = Findings.at_site_in_func("", "dynamic")
    end

    test "builders given a function ID and an unresolvable site keep the real module" do
      # Each of these once passed the function ID where a module string
      # belongs, so a site of "" or "dynamic" anchored at
      # :"Elixir.Foo.Bar:baz/1".
      for {mod, relation, row} <- [
            {Failure, :unhandled_failure, ["Foo.Bar:baz/1", "", "rescue", "", ""]},
            {Failure, :unhandled_failure, ["Foo.Bar:baz/1", "dynamic", "rpc", "case", ""]},
            {Argus.Analyses.Startup, :blocks_on_peer,
             ["Foo.Bar:baz/1", "init", "unknown", "global", "", "", "dynamic", "trans"]},
            {Argus.Analyses.Startup, :post_start_initialization,
             ["Foo.Bar:baz/1", "", "X:y/0", ""]},
            {Argus.Analyses.Blocking, :partial_noproc_catch,
             ["Foo.Bar:baz/1", "", "GenServer:call/2", "dynamic", ""]}
          ] do
        attrs = mod.finding(relation, row)
        assert attrs.module == Foo.Bar, "#{relation}: #{inspect(attrs.module)}"
        assert attrs.mfa == {Foo.Bar, :baz, 1}
      end

      frame =
        Mailbox.evidence(:task_yield_site, ["Foo.Bar:baz/1", "yield_linked", ""])

      assert frame.module == Foo.Bar
    end

    test "inconsistent handling on Erlang code keeps its module anchor" do
      attrs =
        Failure.finding(:inconsistent_handling, [
          ":my_mod:run/1",
          "dynamic",
          ":gen_server:call/2",
          "result_checked",
          "5",
          "1",
          "",
          "",
          "",
          ""
        ])

      assert attrs.module == :my_mod
      assert attrs.mfa == {:my_mod, :run, 1}

      frame =
        Failure.evidence(:handling_site, [
          ":gen_server:call/2",
          "result_checked",
          "",
          ":my_mod:other/0",
          "",
          "",
          ""
        ])

      assert frame.module == :my_mod
    end

    test "at_instr parses instruction IDs into full anchors" do
      assert %{module: :lists, mfa: {:lists, :map, 2}, instr: %InstrId{idx: 7}} =
               Findings.at_instr(":lists:map/2#7")

      assert %{module: nil, mfa: nil, instr: nil} = Findings.at_instr("garbage")
    end
  end

  describe "new/4 remediation fields" do
    test "defaults to no at_label and no help" do
      attrs = Findings.new(:warning, "Title", "Detail.")

      assert attrs.at_label == nil
      assert attrs.help == []
    end

    test "carries at_label and help through" do
      attrs =
        Findings.new(:warning, "Title", "Detail.",
          at: Findings.at_module("MyApp.Sup"),
          at_label: "supervision tree defined here",
          help: ["use `rest_for_one`", "reorder the children"]
        )

      assert attrs.at_label == "supervision tree defined here"
      assert attrs.help == ["use `rest_for_one`", "reorder the children"]
    end

    test "rejects a non-string at_label" do
      assert_raise ArgumentError, ~r/:at_label must be a string/, fn ->
        Findings.new(:warning, "Title", "Detail.", at_label: :here)
      end
    end

    test "carries at_source through and rejects an empty one" do
      attrs = Findings.new(:warning, "Title", "Detail.", at_source: ":api_key")
      assert attrs.at_source == ":api_key"
      assert Findings.new(:warning, "Title", "Detail.").at_source == nil

      assert_raise ArgumentError, ~r/:at_source must be a non-empty string/, fn ->
        Findings.new(:warning, "Title", "Detail.", at_source: "")
      end
    end

    test "rejects help that is not a list of strings" do
      assert_raise ArgumentError, ~r/:help must be a list of strings/, fn ->
        Findings.new(:warning, "Title", "Detail.", help: "use rest_for_one")
      end

      assert_raise ArgumentError, ~r/:help must be a list of strings/, fn ->
        Findings.new(:warning, "Title", "Detail.", help: [:not_a_string])
      end
    end
  end

  defmodule CustomEvidence do
    @moduledoc false
    alias Argus.Findings

    def name, do: :custom_evidence

    def output_relations do
      [
        %{name: :finding, fields: [{:mod, :symbol, "module"}], doc: "a finding"},
        %{
          name: :witness,
          fields: [{:mod, :symbol, "module"}, {:site, :symbol, "site"}],
          evidence: %{of: :finding, on: [:mod]},
          doc: "its witnesses"
        }
      ]
    end

    def finding(:finding, [mod]), do: Findings.new(:info, "t", "d", at: Findings.at_module(mod))
    def evidence(:witness, [_mod, site]), do: Findings.related("witness", Findings.at_instr(site))
  end

  defmodule TwoEvidence do
    @moduledoc false
    def name, do: :two_evidence

    def output_relations do
      CustomEvidence.output_relations() ++
        [
          %{
            name: :other_witness,
            fields: [{:mod, :symbol, "module"}],
            evidence: %{of: :finding, on: [:mod]},
            doc: "more witnesses"
          }
        ]
    end

    defdelegate finding(relation, row), to: CustomEvidence
  end

  defmodule Fragile do
    @moduledoc false
    alias Argus.Findings

    def name, do: :fragile
    defdelegate output_relations, to: CustomEvidence

    def finding(:finding, ["boom"]), do: raise("no boom")
    def finding(:finding, [mod]), do: Findings.new(:info, "t", "d", at: Findings.at_module(mod))

    def evidence(:witness, [_mod, "boom"]), do: raise("no boom")
    def evidence(:witness, [_mod, site]), do: Findings.related("witness", Findings.at_instr(site))
  end
end
