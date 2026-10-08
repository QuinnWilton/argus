defmodule Argus.Graph.ParamFlowReturnsTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Extractors.ParamFlow
  alias Argus.Test.{Files, Peer}
  alias Roux.{Blob, Input, QueryLog, Runtime, Session}

  @moduletag :tmp_dir

  # One peer for the module: a fresh VM works out every query's code
  # version before it opens a graph, seconds of CPU, and each test's
  # modules and store are its own.
  setup_all do
    peer = Peer.start!()
    Peer.run(peer, fn -> Code.compiler_options(ignore_module_conflict: true) end)
    %{peer: peer}
  end

  setup %{tmp_dir: dir} do
    on_exit(fn -> Files.rm_rf!(dir) end)
    :ok
  end

  test "helper body edits invalidate caller flow and unchanged modules stay warm", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      session = Session.open(modules: Argus.Graph.modules(), blob: Path.join(dir, "store"))
      log = QueryLog.start(session.db)

      try do
        for {helper, expected} <- [{~s("fixed"), []}, {"value", ["0"]}, {~s("fixed"), []}] do
          [{_, beam}] =
            Code.compile_string("""
            defmodule ParamFlowReturnEditFixture do
              def caller(value), do: value |> helper() |> String.to_atom()
              def mapped(value), do: [value] |> Enum.map(&helper/1) |> Enum.join() |> String.to_atom()
              def helper(value) do
                _ = value
                #{helper}
              end
            end
            """)

          Input.set(session.db, :beam, :fixture, %{data: beam, hash: Blob.digest(beam)})
          {:ok, graph} = Runtime.query(session.db, :extraction_producer, {:fixture, ParamFlow})
          {:ok, fresh} = Argus.Pipeline.extract_module(beam, producers: [ParamFlow])
          assert rows(graph) == rows(Map.fetch!(fresh.facts, ParamFlow))

          for function <- ["caller", "mapped"] do
            actual =
              for [_site, "ParamFlowReturnEditFixture:" <> name, "0", param] <-
                    Map.get(rows(graph), :sink_arg_derived, []),
                  name == "#{function}/1",
                  do: param

            assert actual == expected
          end

          QueryLog.reset(log)

          assert {:ok, ^graph} =
                   Runtime.query(session.db, :extraction_producer, {:fixture, ParamFlow})

          assert QueryLog.executions(log, :extraction_producer) == []
        end
      after
        QueryLog.stop(log)
        Session.close(session)
      end
    end)
  end

  test "finite private bounds follow caller, export, and escape edits", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      session = Session.open(modules: Argus.Graph.modules(), blob: Path.join(dir, "bounds"))

      try do
        variants = [
          {"~c\"fixed\"", "defp", "", true},
          {"value", "defp", "", false},
          {"~c\"fixed\"", "def", "", false},
          {"~c\"fixed\"", "defp", "def captured, do: &helper/1", false},
          {"~c\"fixed\"", "defp", "", true}
        ]

        for {argument, visibility, capture, bounded?} <- variants do
          [{_, beam}] =
            Code.compile_string("""
            defmodule ParamFlowPrivateBoundEditFixture do
              def caller(value) do
                _ = value
                helper(#{argument})
              end
              #{visibility} helper(value), do: List.to_atom(value)
              #{capture}
            end
            """)

          Input.set(session.db, :beam, :fixture, %{data: beam, hash: Blob.digest(beam)})
          {:ok, graph} = Runtime.query(session.db, :extraction_producer, {:fixture, ParamFlow})
          {:ok, fresh} = Argus.Pipeline.extract_module(beam, producers: [ParamFlow])
          assert rows(graph) == rows(Map.fetch!(fresh.facts, ParamFlow))

          actual =
            Enum.any?(Map.get(rows(graph), :sink_arg_bounded, []), fn
              [_, "ParamFlowPrivateBoundEditFixture:helper/1", "0", ""] -> true
              _ -> false
            end)

          assert actual == bounded?
        end
      after
        Session.close(session)
      end
    end)
  end

  defp rows(facts),
    do: Map.new(facts, fn {relation, bytes} -> {relation, Argus.Tsv.decode(bytes)} end)
end
