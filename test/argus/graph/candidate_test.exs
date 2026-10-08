defmodule Argus.Graph.CandidateTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Pipeline.Disassemble
  alias Argus.Test.{Files, Peer}
  alias Roux.{Blob, Input, QueryLog, Runtime, Session}

  @moduletag :tmp_dir

  @producers [
    Argus.Extractors.CallbackTag,
    Argus.Extractors.Endpoint,
    Argus.Extractors.Reply,
    Argus.Extractors.Router
  ]

  # One peer for both tests: a fresh VM works out every query's code
  # version before it opens a graph, and each test's module and store
  # are its own.
  setup_all do
    peer = Peer.start!()
    Peer.run(peer, fn -> Code.compiler_options(ignore_module_conflict: true) end)
    %{peer: peer}
  end

  setup %{tmp_dir: dir} do
    on_exit(fn -> Files.rm_rf!(dir) end)
    :ok
  end

  test "candidate additions and removals preserve direct extraction results", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      session = Argus.Graph.open(store: Path.join(dir, "store"))
      Argus.Graph.set_environment(session.db, stamps: false)
      log = QueryLog.start(session.db)

      try do
        for callbacks? <- [false, true, false] do
          beam = compile(callbacks?)
          Input.set(session.db, :beam, :fixture, %{data: beam, hash: Blob.digest(beam)})
          QueryLog.reset(log)
          {:ok, disassembly} = Disassemble.disassemble_path(beam)

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

  test "instruction candidates become active after edits and keep dynamic and literal cases", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      session = Argus.Graph.open(store: Path.join(dir, "instructions"))
      Argus.Graph.set_environment(session.db, stamps: false)
      log = QueryLog.start(session.db)

      producers = [
        Argus.Extractors.Handles,
        Argus.Extractors.Sockets,
        Argus.Extractors.Tls,
        Argus.Extractors.ProcessRegistry
      ]

      active = """
      def open, do: (File.open!("file"); :ok)
      def socket(host), do: :gen_tcp.connect(host, 443, [])
      def dynamic(transport, socket), do: transport.setopts(socket, active: :once)
      def options(socket), do: helper(socket, active: true)
      def helper(socket, opts), do: {socket, opts}
      def tls, do: [options: [verify: :verify_none]]
      def registry(pid), do: Process.register(pid, :name)
      def error(value), do: value == :already_started
      """

      try do
        for body <- ["", active, ""] do
          [{_, beam}] =
            Code.compile_string(
              "defmodule InstructionCandidates do\n def ordinary(x), do: x\n" <> body <> "\nend"
            )

          Input.set(session.db, :beam, :fixture, %{data: beam, hash: Blob.digest(beam)})
          {:ok, data} = Disassemble.disassemble_path(beam)
          QueryLog.reset(log)

          for producer <- producers do
            {:ok, rows} = Runtime.query(session.db, :extraction_producer, {:fixture, producer})

            {:ok, expected} =
              Argus.Pipeline.extract_data(data, producers: [producer], trace_imprecision: true)

            expected = expected.facts[producer]

            normalize = fn facts ->
              Map.new(facts, fn {r, b} ->
                {r, :binary.split(b, "\n", [:global]) |> Enum.sort()}
              end)
            end

            assert normalize.(rows) == normalize.(expected)
            assert rows != %{} == (body != "")
          end

          if body == "", do: assert(QueryLog.executions(log, :extraction_local) == [])
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
