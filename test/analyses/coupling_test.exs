defmodule Argus.Analyses.CouplingTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Coupling
  alias Argus.Souffle
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # Beams of `source`, written where Argus.analyze/2 can read them.
  defp compile_beams(source), do: Memo.compile_beams(source)

  describe "sibling_dependency: restart_isolation" do
    test "analyzes coupling under one_for_one supervisors" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.GoodSupervisor,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Memo.analyze(modules, :coupling)

      assert Map.has_key?(results, "sibling_dependency")
    end

    test "wrong_start_order ignores runtime-only call paths" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.RuntimeCallSupervisor,
        Argus.Test.Fixtures.RuntimeCallerWorker,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      # RuntimeCallerWorker calls WorkerA only from handle_call, not init:
      # no later-sibling row.
      assert Rows.where(results, :startup, "blocks_on_peer", ordering: "later") == []
    end

    test "linked coupled pairs are excluded (the hazard is mitigated)" do
      skip_without_souffle()

      # Hand-authored facts pin the negation exactly: A sync-calls its
      # sibling B under a one_for_one supervisor — coupling; adding a
      # process link between them removes the finding, because the exit
      # propagates and both restart together.
      base = %{
        supervisor: [["Sup", "one_for_one"]],
        # Anchor site split out of `supervisor` in schema v8.
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "A", "permanent", "worker"],
          ["Sup", "1", "B", "permanent", "worker"]
        ],
        function_def: [["A:call_b/0", "A", "call_b", "0", "1", "1"]],
        sync_call: [["A:call_b/0", "B"]]
      }

      assert [[_sup, "A", "B", "restart_isolation", "call", _site, _witness, _call_site | _]] =
               coupling_rows(base)

      linked = Map.put(base, :process_link, [["A", "B"]])
      assert coupling_rows(linked) == []
    end

    test "a link to a pid the points-to analysis resolves excludes the pair" do
      skip_without_souffle()

      # LinkA links to LinkB's registered pid: process_link's target is
      # "dynamic", pid_signal names it, and the points-to analysis
      # resolves the name to LinkB's server.
      paths =
        compile_beams("""
        defmodule Argus.CouplingTest.LinkSup do
          use Supervisor
          def init(_) do
            Supervisor.init([Argus.CouplingTest.LinkA, Argus.CouplingTest.LinkB],
              strategy: :one_for_one
            )
          end
        end

        defmodule Argus.CouplingTest.LinkA do
          use GenServer
          def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

          def init(_) do
            Process.link(Process.whereis(Argus.CouplingTest.LinkB))
            {:ok, nil}
          end

          def handle_call(:x, _from, s), do: {:reply, GenServer.call(Argus.CouplingTest.LinkB, :y), s}
        end

        defmodule Argus.CouplingTest.LinkB do
          use GenServer
          def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
          def init(_), do: {:ok, nil}
          def handle_call(:y, _from, s), do: {:reply, :ok, s}
        end
        """)

      assert {:ok, results} = Memo.analyze(paths, :coupling)
      assert results["sibling_dependency"] == []
    end

    test "a temporary spec the start hands over leaves the supervisor out" do
      skip_without_souffle()

      # redix#334's fix: the Manager restarts its connections from :DOWN,
      # and each start's spec says restart: :temporary through
      # Supervisor.child_spec/2, so the supervisor never restarts one.
      paths =
        compile_beams("""
        defmodule Argus.CouplingTest.TempChild do
          use GenServer
          def start_link(a), do: GenServer.start_link(__MODULE__, a)
          def init(a), do: {:ok, a}
        end

        defmodule Argus.CouplingTest.TempOwner do
          use GenServer
          def init(_), do: {:ok, %{pid: nil}}

          def handle_info(:start, state), do: {:noreply, start(state)}
          def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, start(state)}

          defp start(state) do
            spec = Supervisor.child_spec({Argus.CouplingTest.TempChild, []}, restart: :temporary)
            {:ok, pid} = DynamicSupervisor.start_child(Argus.CouplingTest.DynSup, spec)
            Process.monitor(pid)
            %{state | pid: pid}
          end
        end
        """)

      assert {:ok, results} = Memo.analyze(paths, :coupling)
      assert Map.get(results, "dual_restart_authority", []) == []
    end

    test "a monitor of a started child the points-to analysis follows is a restart authority" do
      skip_without_souffle()

      # The monitor reads the pid from state in a helper: monitor_call's
      # target is "dynamic", and the points-to analysis follows the field
      # back to the DynamicSupervisor.start_child that returned it.
      paths =
        compile_beams("""
        defmodule Argus.CouplingTest.MonChild do
          use GenServer
          def start_link(a), do: GenServer.start_link(__MODULE__, a)
          def init(a), do: {:ok, a}
        end

        defmodule Argus.CouplingTest.MonOwner do
          use GenServer
          def init(_), do: {:ok, %{pid: nil}}

          def handle_info(:start, state), do: {:noreply, start(state)}
          def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, start(state)}

          defp start(state) do
            {:ok, pid} =
              DynamicSupervisor.start_child(Argus.CouplingTest.DynSup, {Argus.CouplingTest.MonChild, []})

            watch(%{state | pid: pid})
          end

          defp watch(state) do
            Process.monitor(state.pid)
            state
          end
        end
        """)

      assert {:ok, results} = Memo.analyze(paths, :coupling)

      assert [["Argus.CouplingTest.MonOwner", _sup, "Argus.CouplingTest.MonChild" | _] | _] =
               results["dual_restart_authority"]
    end

    test "a witness's own :gen_statem call anchors the coupling" do
      skip_without_souffle()

      # A:h/0 reaches B only through A:helper/0; its own call is an
      # Erlang-spelled :gen_statem.call, the anchor a GenServer.call
      # would have been.
      facts = %{
        supervisor: [["Sup", "one_for_one"]],
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "A", "permanent", "worker"],
          ["Sup", "1", "B", "permanent", "worker"]
        ],
        function_def: [
          ["A:h/0", "A", "h", "0", "1"],
          ["A:helper/0", "A", "helper", "0", "0"],
          ["B:pure/1", "B", "pure", "1", "1"],
          ["B:ask/0", "B", "ask", "0", "1"]
        ],
        remote_call: [
          ["A:helper/0#1", "A:helper/0", "B", "pure", "1"],
          ["A:h/0#4", "A:h/0", ":gen_statem", "call", "2"]
        ],
        local_call: [["A:h/0#2", "A:h/0", "A:helper/0", "0"]],
        sync_call: [["B:ask/0", "C"]]
      }

      assert ["A:h/0#4"] =
               for(
                 [_, "A", "B", "restart_isolation", _, _, "A:h/0", site | _] <-
                   coupling_rows(facts),
                 do: site
               )
    end

    test "the coupling site is the call into the sibling, not one inside it" do
      skip_without_souffle()

      # A reaches B through a helper module H. B's record/1 is a
      # default-argument head calling record/2, B's own function: the
      # walk reaches it through H's call, and B's inner call sorts first
      # ("B:" < "H:"). Anchored there, every caller of B got the same
      # line of B's API. The site is H's call into B.
      facts = %{
        supervisor: [["Sup", "one_for_one"]],
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "A", "permanent", "worker"],
          ["Sup", "1", "B", "permanent", "worker"]
        ],
        function_def: [
          ["A:h/0", "A", "h", "0", "1"],
          ["H:report/1", "H", "report", "1", "1"],
          ["B:record/1", "B", "record", "1", "1"],
          ["B:record/2", "B", "record", "2", "1"]
        ],
        remote_call: [
          ["A:h/0#1", "A:h/0", "H", "report", "1"],
          ["H:report/1#2", "H:report/1", "B", "record", "1"]
        ],
        local_call: [["B:record/1#3", "B:record/1", "B:record/2", "2"]],
        async_cast: [["B:record/2", "dynamic"]]
      }

      assert ["H:report/1#2"] =
               for(
                 [_, "A", "B", "restart_isolation", "cast", _, "A:h/0", site | _] <-
                   coupling_rows(facts),
                 do: site
               )
    end

    test "a cast-only dependency is graded as a one-way coupling" do
      skip_without_souffle()

      base = %{
        supervisor: [["Sup", "one_for_one"]],
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "A", "permanent", "worker"],
          ["Sup", "1", "B", "permanent", "worker"]
        ],
        function_def: [["A:cast_b/0", "A", "cast_b", "0", "1", "1"]],
        async_cast: [["A:cast_b/0", "B"]]
      }

      assert [[_sup, "A", "B", "restart_isolation", "cast", _site, "A:cast_b/0", _call_site | _]] =
               coupling_rows(base)

      # One sync call anywhere along the dependency makes it a call coupling.
      both = Map.put(base, :sync_call, [["A:cast_b/0", "B"]])
      assert [[_, "A", "B", "restart_isolation", "call", _, _, _ | _]] = coupling_rows(both)
    end

    test "a dependency inferred from reaching a sibling with a call somewhere is marked, and a prior can doubt it" do
      skip_without_souffle()

      # A's handler reaches B's pure/1; B's ask/0 calls a server. No
      # resolved call from A to B: the module-level clause alone couples
      # them, and the row says so.
      base = %{
        supervisor: [["Sup", "one_for_one"]],
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "A", "permanent", "worker"],
          ["Sup", "1", "B", "permanent", "worker"]
        ],
        function_def: [
          ["A:h/0", "A", "h", "0", "1"],
          ["B:pure/1", "B", "pure", "1", "1"],
          ["B:ask/0", "B", "ask", "0", "1"]
        ],
        remote_call: [["A:h/0#1", "A:h/0", "B", "pure", "1"]],
        sync_call: [["B:ask/0", "C"]]
      }

      assert [[_, "A", "B", "restart_isolation", _, _, _, _, "inferred", "0"]] =
               coupling_rows(base)

      doubted = Map.put(base, :prior_talks_to_process, [["B", "120"]])

      assert [[_, "A", "B", "restart_isolation", _, _, _, _, "doubted", "120"]] =
               coupling_rows(doubted)

      # At 0.7 the model thinks B is a process after all: the inference stands.
      confirmed = Map.put(base, :prior_talks_to_process, [["B", "700"]])

      assert [[_, "A", "B", "restart_isolation", _, _, _, _, "inferred", "0"]] =
               coupling_rows(confirmed)

      # A resolved call is never doubted, whatever the prior says.
      resolved =
        base
        |> Map.put(:sync_call, [["A:h/0", "B"], ["B:ask/0", "C"]])
        |> Map.put(:prior_talks_to_process, [["B", "50"]])

      assert [[_, "A", "B", "restart_isolation", "call", _, _, _, "resolved", "0"]] =
               coupling_rows(resolved)
    end

    test "a doubted row is the same finding a severity step down, labelled and heuristic" do
      row = [
        "Sup",
        "A",
        "B",
        "restart_isolation",
        "call",
        "Sup:init/1#3",
        "A:h/0",
        "A:h/0",
        "doubted",
        "120"
      ]

      finding = Coupling.finding(:sibling_dependency, row)
      assert finding.severity == :info
      assert finding.provenance == :heuristic
      assert finding.confidence == 880
      assert List.last(finding.help) =~ "does not talk to a process"
      assert List.last(finding.help) =~ "(p=0.88)"
      # The anchor label still says what the anchor line is.
      refute finding.at_label =~ "heuristic"
      assert finding.title == "Coupled children under one_for_one"

      plain =
        Coupling.finding(:sibling_dependency, List.replace_at(row, 8, "inferred"))

      assert plain.severity == :warning and plain.provenance == :structural
    end

    defp coupling_rows(facts) do
      assert {:ok, results} = Argus.Test.Memo.run_rules(facts, :coupling)
      results["sibling_dependency"] || []
    end
  end
end
