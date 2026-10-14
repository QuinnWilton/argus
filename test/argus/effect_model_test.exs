defmodule Argus.EffectModelTest do
  use ExUnit.Case, async: true

  alias Argus.EffectModel

  doctest Argus.EffectModel

  describe "classify/2,3 and mode/2" do
    test "classifies the three buckets" do
      assert EffectModel.classify("IO", "puts") == {:impure, :io, :write}
      assert EffectModel.classify(":ets", "insert") == {:impure, :ets, :write}
      assert EffectModel.classify(":erlang", "put") == {:impure, :process_dict, :write}
      # A clock read is a read. It is still an effect (the result depends
      # on when it ran), but the contracts about durability should not
      # treat `now()` as something to roll back or something lost when
      # terminate/2 is skipped.
      assert EffectModel.classify(":erlang", "monotonic_time") == {:impure, :time, :read}

      assert EffectModel.classify("Enum", "map") == :pure
      assert EffectModel.classify(":lists", "reverse") == :pure
      assert EffectModel.classify(":erlang", "+") == :pure

      assert EffectModel.classify("MyApp.Repo", "all") == :unknown
      assert EffectModel.classify("SomeDep", "call") == :unknown
    end

    test "a function-level entry beats its module's default" do
      # :erlang is pure by default with a listed impure minority. If that
      # precedence inverted, every arithmetic BIF would become unprovable
      # and the analysis would report nothing useful.
      assert EffectModel.classify(":erlang", "put") == {:impure, :process_dict, :write}
      assert EffectModel.classify(":erlang", "length") == :pure
    end

    test "a call that runs what it is given beats its module's category" do
      # :timer is a process module, but :timer.tc/2 runs the function handed
      # to it, so its effects are its argument's. Classified by module, a
      # `:timer.tc(fn -> release_lease() end)` in terminate/2 gets reported
      # as a clock read while the lease release goes unmentioned — the right
      # module for the wrong reason, which is indistinguishable from luck.
      assert EffectModel.classify(":timer", "tc") == {:opaque, :dot_dispatch}
      assert EffectModel.classify(":timer", "sleep") == {:impure, :process, :write}
    end

    test "a pure function of an impure module is pure, and the dictionary is a dictionary" do
      # :inet is sockets and name resolution; its address parsing and
      # printing are string work. :io_lib builds what :io would write.
      assert EffectModel.classify(":inet", "ntoa") == :pure
      assert EffectModel.classify(":inet", "parse_strict_address") == :pure
      assert EffectModel.classify(":inet", "getaddr") == {:impure, :network, :write}
      assert EffectModel.classify(":io_lib", "format") == :pure
      assert EffectModel.classify(":io", "format") == {:impure, :io, :write}

      # Elixir's Process module is a process module, but put/get are the
      # process dictionary, as :erlang's are.
      assert EffectModel.classify("Process", "put") == {:impure, :process_dict, :write}
      assert EffectModel.classify("Process", "get") == {:impure, :process_dict, :read}
      assert EffectModel.classify("Process", "send_after") == {:impure, :process, :write}
    end

    test "reads are impure but distinguished from writes" do
      # The context-imposed contracts look only at writes, because a read
      # has nothing to roll back and nothing to lose by being skipped. Path
      # and System query the environment without changing it.
      assert EffectModel.classify("Path", "expand") == {:impure, :io, :read}
      assert EffectModel.classify("System", "tmp_dir!") == {:impure, :port, :read}
      assert EffectModel.classify("File", "cwd") == {:impure, :io, :read}

      assert EffectModel.classify("File", "write") == {:impure, :io, :write}
      assert EffectModel.classify("File", "rm_rf") == {:impure, :io, :write}
    end

    test "an Erlang module is classified as its Elixir twin is" do
      # A two-spelling API covered on one side reads the other spelling as
      # no effect, or as an unknown one: hackney's stop_pool/1 terminated
      # a pool through :supervisor, which the model did not know, while
      # the same call through Supervisor was a process write.
      for {elixir, erlang} <- [
            {{"Supervisor", "terminate_child"}, {":supervisor", "terminate_child"}},
            {{"DynamicSupervisor", "start_child"}, {":supervisor", "start_child"}},
            {{"System", "stop"}, {":init", "stop"}},
            {{"Path", "join"}, {":filename", "join"}},
            {{"Path", "absname"}, {":filename", "absname"}},
            {{"URI", "parse"}, {":uri_string", "parse"}},
            {{"Base", "encode64"}, {":base64", "encode"}},
            {{"Port", "connect"}, {":erlang", "port_connect"}},
            {{"DateTime", "utc_now"}, {":calendar", "universal_time"}}
          ] do
        assert EffectModel.classify(elem(erlang, 0), elem(erlang, 1)) ==
                 EffectModel.classify(elem(elixir, 0), elem(elixir, 1))
      end

      assert EffectModel.classify(":init", "get_plain_arguments") == {:impure, :port, :read}
      assert EffectModel.classify(":filename", "basedir") == {:impure, :port, :read}
      assert EffectModel.classify(":calendar", "date_to_gregorian_days") == :unknown
    end

    test "every category used is declared in the type's domain" do
      known =
        ~w(io logging process process_dict ets port node time random network code_loading)a

      assert Enum.sort(EffectModel.categories()) == Enum.sort(known)
    end
  end
end
