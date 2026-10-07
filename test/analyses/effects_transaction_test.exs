defmodule Argus.Analyses.EffectsTransactionTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Purity.Effects
  alias Argus.Test.Fixtures.Transaction, as: T
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  @all [
    T.FakeRepo,
    T.Unsafe,
    T.UnsafeIndirect,
    T.Sleeps,
    T.LogsOnly,
    T.ReadsConfig,
    T.EffectOutside
  ]

  defp findings(modules \\ @all) do
    assert {:ok, r} = Memo.analyze(modules, :effects)

    r
    |> Rows.where(:effects, "effect_in_context",
      context: "transaction",
      drop: [:context, :site, :opened]
    )
    |> Enum.uniq()
  end

  defp for_module(rows, fragment) do
    Enum.filter(rows, fn [caller, _repo, _cat, _api, _via] ->
      String.contains?(caller, fragment)
    end)
  end

  describe "detection" do
    test "an unrollbackable effect in the transaction body is reported" do
      assert [[caller, repo, "network", api, via]] = for_module(findings(), "Unsafe:create/1")

      assert caller =~ "Unsafe:create/1"
      assert repo =~ "FakeRepo"
      assert api =~ "httpc.request"
      assert via =~ "-create/1-fun-0-", "should name the closure, not the enclosing function"
    end

    test "a start in the transaction is a process effect; the new process's own are not repeated" do
      rows = findings([T.FakeRepo, T.StreamsBeforeCommit, T.TaskBeforeCommit])

      # One row each: the spawn and the Task start, where the work is
      # handed to another process. The pusher's dispatch and sends, and
      # the task's request, are that process's.
      assert [[_, _, "process", spawn, stream]] = for_module(rows, "StreamsBeforeCommit")
      assert spawn =~ "spawn"
      assert stream =~ "stream/2"

      # The task's webhook is sent whether or not the transaction commits,
      # and again on a retry: reported beside the start, at its own tier.
      assert [[_, _, "network", _, _], [_, _, "process", start, _via]] =
               Enum.sort(for_module(rows, "TaskBeforeCommit"))

      assert start =~ "Task"
    end

    test "a broadcast, an HTTP request, and Repo.transact's fun" do
      rows =
        findings([
          T.FakeRepo,
          T.BroadcastBeforeCommit,
          T.BroadcastAfterCommit,
          T.TransactBeforeCommit
        ])

      assert [[_, _, "process", "Phoenix.PubSub.broadcast/3", _]] =
               for_module(rows, "BroadcastBeforeCommit")

      assert for_module(rows, "BroadcastAfterCommit") == []

      assert [[_, repo, "network", "Req.post!/2", _]] = for_module(rows, "TransactBeforeCommit")
      assert repo =~ "FakeRepo"
    end

    test "an effect several calls inside the transaction is attributed to its site" do
      assert [[_caller, _repo, "network", _api, via]] =
               for_module(findings(), "UnsafeIndirect:create/1")

      assert via =~ "deliver/1", "blamed the transaction rather than the function at fault"
    end

    test "sleeping inside a transaction is reported" do
      # The purest form of the connection-holding problem: a pooled
      # connection checked out and doing nothing.
      assert [[_caller, _repo, "process", api, _via]] = for_module(findings(), "Sleeps:create/1")
      assert api =~ "sleep"
    end

    test "the repo is found by behaviour, not by being called Repo" do
      # FakeRepo only declares @behaviour Ecto.Repo. An app's own repo can
      # be called anything, so matching on the name would miss most of them.
      assert [[_c, repo, _cat, _api, _v] | _] = for_module(findings(), "Unsafe:create/1")
      assert repo =~ "FakeRepo"
    end
  end

  describe "the transaction a body belongs to" do
    test "a closure in a function that opens transactions on two repos is paired with its own" do
      # Joining the caller's transaction sites apart from its body paired
      # the closure with every repo the function touched; the finding,
      # deduplicated on (func, context, category, api), then named
      # whichever repo sorted first — AuditRepo, which never saw it. The
      # call the closure is handed to names its repo (handed_closure).
      assert [[_caller, repo, "network", _api, _via]] =
               for_module(findings([T.FakeRepo, T.AuditRepo, T.TwoRepos]), "TwoRepos")

      assert repo =~ "FakeRepo"
    end

    test "the closure handed to the transaction is its body, beside another the function builds" do
      assert [[_caller, repo, "network", api, via]] =
               for_module(findings([T.FakeRepo, T.TwoClosures]), "TwoClosures")

      assert repo =~ "FakeRepo"
      assert api =~ "httpc.request"
      assert via =~ "-create/1-fun-1-"
    end

    test "the finding anchors at the transaction call, with the effect as a frame" do
      assert {:ok, %{findings: findings}} =
               Memo.run_analyses([T.FakeRepo, T.Unsafe], analyses: [:effects])

      assert [finding] = Enum.filter(findings, &(&1.module == T.Unsafe))
      assert finding.at_label == "opens the transaction here"
      assert %Argus.InstrId{func: "create", arity: 1} = finding.instr

      assert [%{label: label, instr: %Argus.InstrId{func: effect_func}}] = finding.related
      assert label =~ "network I/O inside it"
      assert effect_func =~ "-create/1-fun-0-"
    end
  end

  describe "what must not be reported" do
    # These three are the difference between a usable analysis and one
    # nobody runs twice.

    test "logging inside a transaction is fine" do
      assert for_module(findings(), "LogsOnly") == [],
             "Logger is the most common effect inside a transaction by far"
    end

    test "reading configuration inside a transaction is fine" do
      # Impure — it breaks referential transparency — but there is nothing
      # for a rollback to undo. This is why impure_call carries a mode.
      assert for_module(findings(), "ReadsConfig") == []
    end

    test "an effect after the transaction commits is the correct shape" do
      assert for_module(findings(), "EffectOutside") == []
    end
  end

  describe "the read/write distinction" do
    @tag flowlog: false
    test "reads and writes in the same module are told apart" do
      # The model dimension this analysis rests on. Without it every
      # Application.get_env/2 in a transaction is a finding, and the real
      # ones drown.
      assert {:impure, :process, :read} = Effects.classify("Application", "get_env")
      assert {:impure, :process, :write} = Effects.classify("Application", "put_env")

      assert {:impure, :io, :read} = Effects.classify("File", "read")
      assert {:impure, :io, :write} = Effects.classify("File", "write")

      assert {:impure, :ets, :read} = Effects.classify(":ets", "lookup")
      assert {:impure, :ets, :write} = Effects.classify(":ets", "insert")
    end

    @tag flowlog: false
    test "an unlisted effect defaults to write" do
      # The safe direction: a false "irreversible" costs a look, a false
      # "harmless" costs the bug.
      assert {:impure, :network, :write} = Effects.classify(":httpc", "request")

      assert {:impure, :process, :write} = Effects.classify("Phoenix.PubSub", "broadcast")
      assert {:impure, :process, :read} = Effects.classify("Phoenix.PubSub", "node_name")
      assert {:impure, :network, :write} = Effects.classify("Req", "get!")
      assert Effects.classify("Req", "new") != {:impure, :network, :write}

      # :timer arms timers, and converts units without one.
      assert {:impure, :process, :write} = Effects.classify(":timer", "send_after")
      assert :pure = Effects.classify(":timer", "seconds")
      assert :pure = Effects.classify(":timer", "hms")
      assert Effects.mode("SomeUnknown", "thing") == :write
    end

    test "purity still rejects reads, which reversibility does not" do
      # The same call is disqualifying for one contract and harmless for
      # the other — which is the whole reason for two dimensions.
      assert for_module(findings(), "ReadsConfig") == []

      assert {:impure, :process_dict, :read} = Effects.classify("Process", "get")
    end
  end
end
