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

      # Hand-authored facts pin the negation exactly: A's init/1 registers
      # with its sibling B, whose handler keeps it as an ETS row, under a
      # one_for_one supervisor — coupling; adding a process link between
      # them removes the finding, because the exit propagates and both
      # restart together.
      base = registered()

      assert [[_sup, "A", "B", "restart_isolation", "table", _site, _store, "A:init/1#2" | _]] =
               coupling_rows(base)

      linked = Map.put(base, :process_link, [["A", "B"]])
      assert coupling_rows(linked) == []
    end

    test "a link to a pid the points-to analysis resolves excludes the pair" do
      skip_without_souffle()

      # LinkA joins LinkB when it starts, and links to LinkB's registered
      # pid: process_link's target is "dynamic", pid_signal names it, and
      # the points-to analysis resolves the name to LinkB's server.
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
            :ok = GenServer.call(Argus.CouplingTest.LinkB, {:join, self()})
            {:ok, nil}
          end
        end

        defmodule Argus.CouplingTest.LinkB do
          use GenServer
          def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
          def init(_), do: {:ok, %{members: []}}
          def handle_call({:join, pid}, _from, s), do: {:reply, :ok, %{s | members: [pid | s.members]}}
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

    test "the coupling site is the call into the sibling, not one inside it" do
      skip_without_souffle()

      # A's init/1 reaches B through a helper module H. B's record/1 is a
      # default-argument head calling record/2, B's own function, which
      # makes the call B's handler keeps. The site is H's call into B, not
      # B's call inside its own API: anchored there, every caller of B
      # got the same line of B's API.
      facts =
        registered()
        |> Map.merge(%{
          function_def: [
            ["A:init/1", "A", "init", "1", "1"],
            ["H:report/1", "H", "report", "1", "1"],
            ["B:record/1", "B", "record", "1", "1"],
            ["B:record/2", "B", "record", "2", "1"],
            ["B:handle_call/3", "B", "handle_call", "3", "1"]
          ],
          remote_call: [
            ["A:init/1#1", "A:init/1", "H", "report", "1"],
            ["H:report/1#2", "H:report/1", "B", "record", "1"]
          ],
          local_call: [["B:record/1#3", "B:record/1", "B:record/2", "2"]],
          sync_call: [["B:record/2", "B"]],
          sync_call_site: [["B:record/2#4", "B:record/2", "B", "5000"]]
        })

      assert ["H:report/1#2"] =
               for(
                 [_, "A", "B", "restart_isolation", "table", _, _store, site | _] <-
                   coupling_rows(facts),
                 do: site
               )
    end

    test "a registration made by a cast is a coupling, and a cast made on each use is not" do
      skip_without_souffle()

      # B keeps what a cast brings as an ETS row. A casts it from init/1:
      # once, so B's restart loses it. A cast from a handler (A:h/0) is
      # made again on its next use.
      once = %{
        supervisor: [["Sup", "one_for_one"]],
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "B", "permanent", "worker"],
          ["Sup", "1", "A", "permanent", "worker"]
        ],
        implements_behaviour: [["A", "GenServer"], ["B", "GenServer"]],
        function_def: [
          ["A:init/1", "A", "init", "1", "1"],
          ["A:h/0", "A", "h", "0", "1"],
          ["B:handle_cast/2", "B", "handle_cast", "2", "1"]
        ],
        async_cast: [["A:init/1", "B"]],
        remote_call: [["A:init/1#2", "A:init/1", "GenServer", "cast", "2"]],
        ets_op: [["B:handle_cast/2#4", "B:handle_cast/2", "subs", "insert", "write"]]
      }

      assert [[_sup, "A", "B", "restart_isolation", "table", _, "B:handle_cast/2#4", _ | _]] =
               coupling_rows(once)

      per_use =
        once
        |> Map.put(:async_cast, [["A:h/0", "B"]])
        |> Map.put(:remote_call, [["A:h/0#2", "A:h/0", "GenServer", "cast", "2"]])

      assert coupling_rows(per_use) == []
    end

    test "a read and a field reset are not what a restart loses" do
      skip_without_souffle()

      # B's handler for A's request keeps nothing: no ETS write, no
      # monitor, no state it returns sets a field to what init/1 does not.
      read = Map.put(registered(), :ets_op, [])
      assert coupling_rows(read) == []

      reset =
        read
        |> Map.put(:returned_update, [
          ["B:init/1", ":defs", ":none", "*"],
          ["B:handle_call/3", ":defs", ":none", "*"]
        ])
        |> Map.update!(:function_def, &[["B:init/1", "B", "init", "1", "1"] | &1])

      assert coupling_rows(reset) == []

      kept =
        Map.put(reset, :returned_update, [
          ["B:init/1", ":defs", ":none", "*"],
          ["B:handle_call/3", ":defs", "dynamic", "*"]
        ])

      assert [[_, "A", "B", "restart_isolation", "state", _, "B:handle_call/3", _ | _]] =
               coupling_rows(kept)

      # Another clause keeps it: A's call carries no tag the program sees,
      # so it may enter any clause (the clause-by-tag shapes are compiled
      # fixtures, test/soundness/coupling_test.exs).
      other_clause =
        Map.put(reset, :returned_update, [
          ["B:init/1", ":defs", ":none", "*"],
          ["B:handle_call/3", ":defs", "dynamic", ":put"]
        ])

      assert [[_, "A", "B", "restart_isolation", "state" | _]] = coupling_rows(other_clause)
    end

    test "a restart_policy dependency inferred from reaching a sibling with a call somewhere is marked, and a prior can doubt it" do
      skip_without_souffle()

      # A's handler reaches B's pure/1; B's ask/0 calls a server. No
      # resolved call from A to B: the module-level clause alone makes A,
      # a permanent child, depend on B, a temporary one, and the row says
      # so. (What a restart loses, restart_isolation, asks for a request
      # its sibling keeps and is never inferred from reach.)
      base = %{
        supervisor: [["Sup", "one_for_one"]],
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "A", "permanent", "worker"],
          ["Sup", "1", "B", "temporary", "worker"]
        ],
        function_def: [
          ["A:h/0", "A", "h", "0", "1"],
          ["B:pure/1", "B", "pure", "1", "1"],
          ["B:ask/0", "B", "ask", "0", "1"]
        ],
        remote_call: [["A:h/0#1", "A:h/0", "B", "pure", "1"]],
        sync_call: [["B:ask/0", "C"]]
      }

      assert [[_, "A", "B", "restart_policy", "temporary", _, _, _, "inferred", "0"]] =
               coupling_rows(base)

      doubted = Map.put(base, :prior_talks_to_process, [["B", "120"]])

      assert [[_, "A", "B", "restart_policy", _, _, _, _, "doubted", "120"]] =
               coupling_rows(doubted)

      # At 0.7 the model thinks B is a process after all: the inference stands.
      confirmed = Map.put(base, :prior_talks_to_process, [["B", "700"]])

      assert [[_, "A", "B", "restart_policy", _, _, _, _, "inferred", "0"]] =
               coupling_rows(confirmed)

      # A resolved call is never doubted, whatever the prior says.
      resolved =
        base
        |> Map.put(:sync_call, [["A:h/0", "B"], ["B:ask/0", "C"]])
        |> Map.put(:prior_talks_to_process, [["B", "50"]])

      assert [[_, "A", "B", "restart_policy", "temporary", _, _, _, "resolved", "0"]] =
               coupling_rows(resolved)
    end

    test "a doubted row is the same finding a severity step down, labelled and heuristic" do
      row = [
        "Sup",
        "A",
        "B",
        "restart_policy",
        "temporary",
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
      assert finding.title == "Permanent child depends on a temporary sibling"

      plain =
        Coupling.finding(:sibling_dependency, List.replace_at(row, 8, "inferred"))

      assert plain.severity == :warning and plain.provenance == :structural
    end

    test "a keeping inferred from code outside the program is a step down, and says so" do
      row = [
        "Sup",
        "A",
        "B",
        "restart_isolation",
        "handed",
        "Sup:init/1#3",
        "B:handle_call/3#7",
        "A:init/1#2",
        "inferred",
        "0"
      ]

      finding = Coupling.finding(:sibling_dependency, row)
      assert finding.severity == :info
      assert finding.title == "Coupled children under one_for_one"
      assert List.last(finding.help) =~ "outside the program"

      assert Enum.map(finding.related, & &1.label) == [
               "registers with the sibling here",
               "handed on here"
             ]

      shown =
        Coupling.finding(
          :sibling_dependency,
          row |> List.replace_at(4, "table") |> List.replace_at(8, "resolved")
        )

      assert shown.severity == :warning

      assert Enum.map(shown.related, & &1.label) == [
               "registers with the sibling here",
               "kept here"
             ]
    end

    # A's init/1 calls its sibling B, and B's handle_call/3 keeps the
    # request as an ETS row: the smallest restart coupling.
    defp registered do
      %{
        supervisor: [["Sup", "one_for_one"]],
        supervisor_site: [["Sup", "Sup:init/1#3"]],
        supervisor_child: [
          ["Sup", "0", "B", "permanent", "worker"],
          ["Sup", "1", "A", "permanent", "worker"]
        ],
        implements_behaviour: [["A", "GenServer"], ["B", "GenServer"]],
        function_def: [
          ["A:init/1", "A", "init", "1", "1"],
          ["B:handle_call/3", "B", "handle_call", "3", "1"]
        ],
        sync_call: [["A:init/1", "B"]],
        sync_call_site: [["A:init/1#2", "A:init/1", "B", "5000"]],
        ets_op: [["B:handle_call/3#4", "B:handle_call/3", "hooks", "insert", "write"]]
      }
    end

    defp coupling_rows(facts) do
      assert {:ok, results} = Argus.Test.Memo.run_rules(facts, :coupling)
      results["sibling_dependency"] || []
    end
  end
end
