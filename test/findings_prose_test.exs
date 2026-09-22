defmodule Argus.FindingsProseTest do
  @moduledoc """
  Names in a finding's prose are written for a reader, not copied from
  the facts.
  """

  use ExUnit.Case, async: true

  alias Argus.Findings

  describe "call_name/1" do
    test "spells a callee the way a reader writes it" do
      assert Findings.call_name("GenServer:call/2") == "GenServer.call/2"
      assert Findings.call_name(":gen_statem:call/3") == ":gen_statem.call/3"
      assert Findings.call_name(":ets:update_counter/3") == ":ets.update_counter/3"
    end

    test "leaves anything else alone" do
      assert Findings.call_name(":erlang.binary_to_atom/1") == ":erlang.binary_to_atom/1"
      assert Findings.call_name("Oban.Queue.Producer") == "Oban.Queue.Producer"
      assert Findings.call_name("dynamic") == "dynamic"
    end
  end

  describe "rpc_api/1" do
    test "names the function an rpc variant stands for" do
      assert Findings.rpc_api("rpc") == ":rpc.call"
      assert Findings.rpc_api("multicall") == ":rpc.multicall"
      assert Findings.rpc_api("erpc") == ":erpc.call"
      assert Findings.rpc_api("other") == "other"
    end
  end

  describe "compiler-generated function names" do
    defmodule Closures do
      @behaviour Argus.Analysis

      def name, do: :closures
      def description, do: "test"
      def rules_file, do: "none.dl"
      def extractors, do: []

      def output_relations do
        [
          %{
            name: :closure_row,
            fields: [{:func, :symbol, "f"}],
            key: [:func],
            doc: "test relation"
          }
        ]
      end

      def finding(:closure_row, [func]) do
        Findings.new(:info, "#{func} starts a child", "#{func} does it. #{func} again.",
          at: Findings.at_func(func),
          at_label: "in #{func}",
          help: ["look at #{func}"],
          related: [Findings.related("from #{func}", Findings.at_func(func))]
        )
      end
    end

    test "are rendered as the function the closure was written in, everywhere" do
      fun = "Redix.Cluster.Manager:-ensure_connections/2-fun-0-/2"
      [finding] = Findings.build(Closures, %{"closure_row" => [[fun]]})

      plain = "an anonymous function in Redix.Cluster.Manager:ensure_connections/2"
      assert finding.title == "An #{String.slice(plain, 3..-1//1)} starts a child"

      assert finding.detail ==
               "An #{String.slice(plain, 3..-1//1)} does it. An #{String.slice(plain, 3..-1//1)} again."

      assert finding.at_label == "in #{plain}"
      assert finding.help == ["look at #{plain}"]
      assert [%{label: "from " <> ^plain}] = finding.related

      # The anchor keeps the real name: it is what the line table knows.
      assert finding.mfa == {Redix.Cluster.Manager, :"-ensure_connections/2-fun-0-", 2}
    end

    test "other generated shapes and plain names" do
      [finding] =
        Findings.build(Closures, %{"closure_row" => [["M:-run/1-lists^map/1-0-/1"], ["M:run/1"]]})
        |> Enum.sort_by(& &1.title)
        |> Enum.take(1)

      assert finding.title == "An anonymous function in M:run/1 starts a child"
    end
  end
end
