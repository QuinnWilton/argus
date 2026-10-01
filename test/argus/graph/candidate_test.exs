defmodule Argus.Graph.CandidateTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Test.{Files, Peer}
  alias Roux.{Blob, Input, QueryLog, Runtime, Session}

  @moduletag :tmp_dir

  @producers [
    Argus.Extractors.CallbackTag,
    Argus.Extractors.Endpoint,
    Argus.Extractors.Reply,
    Argus.Extractors.Router
  ]

  test "candidate additions and removals preserve direct extraction results", %{tmp_dir: dir} do
    on_exit(fn -> Files.rm_rf!(dir) end)
    peer = Peer.start!()

    Peer.run(peer, fn ->
      Code.compiler_options(ignore_module_conflict: true)
      session = Argus.Graph.open(store: Path.join(dir, "store"))
      Argus.Graph.set_environment(session.db, stamps: false)
      log = QueryLog.start(session.db)

      try do
        for callbacks? <- [false, true, false] do
          beam = compile(callbacks?)
          Input.set(session.db, :beam, :fixture, %{data: beam, hash: Blob.digest(beam)})
          QueryLog.reset(log)
          {:ok, disassembly} = Argus.Pipeline.Disassemble.disassemble_path(beam)

          for producer <- @producers do
            {:ok, actual} = Runtime.query(session.db, :extraction_producer, {:fixture, producer})

            {:ok, expected} =
              Argus.Pipeline.extract_data(disassembly,
                producers: [producer],
                trace_imprecision: true
              )

            assert actual == Map.fetch!(expected.facts, producer)
            assert actual != %{} == callbacks?

            assert {:ok, dependencies} =
                     Roux.Memo.dependencies(
                       session.db,
                       {:extraction_producer, {:fixture, producer}}
                     )

            assert {:extraction_code, producer} in dependencies
          end

          assert Enum.all?(QueryLog.executions(log, :extraction_local), fn
                   {{:fixture, key}, producer} -> producer.candidate?(key)
                 end)

          unless callbacks?, do: assert(QueryLog.executions(log, :extraction_local) == [])
        end
      after
        QueryLog.stop(log)
        Session.close(session)
      end
    end)
  end

  defp compile(callbacks?) do
    callbacks =
      if callbacks? do
        """
        def handle_call(:ping, _from, state), do: {:reply, :pong, state}
        def __sockets__, do: [{"/socket", __MODULE__, [websocket: true]}]
        def __routes__, do: [%{path: "/", verb: :get, plug: __MODULE__, plug_opts: []}]
        """
      else
        ""
      end

    [{_, beam}] =
      Code.compile_string("""
      defmodule CandidateFixture do
        def ordinary(value), do: {:reply, value, :state}
        #{callbacks}
      end
      """)

    beam
  end
end
