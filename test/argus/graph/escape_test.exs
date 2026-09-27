defmodule Argus.Graph.EscapeTest do
  @moduledoc """
  A name holding a tab or a newline is a field like any other: the
  relations it reaches are written escaped, as argus writes them, so the
  solves read them and agree with a fresh run.
  """

  use ExUnit.Case, async: true

  alias Argus.Test.Graph

  @moduletag :souffle
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  test "a function named with a tab and a newline solves, and matches a fresh run", %{
    tmp_dir: dir
  } do
    source = Path.join(dir, "odd.ex")

    File.write!(source, ~S'''
    defmodule ArgusEscapeProbe do
      def unquote(:"tab\there")(), do: unquote(:"new\nline")()
      def unquote(:"new\nline")(), do: GenServer.call(__MODULE__, :ping)
      def caller, do: unquote(:"tab\there")()
    end
    ''')

    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      {:ok, _, _} =
        Kernel.ParallelCompiler.compile_to_path([source], ebin, return_diagnostics: true)
    end)

    paths = %{ArgusEscapeProbe => Path.join(ebin, "Elixir.ArgusEscapeProbe.beam")}
    db = Graph.new_db(paths)

    # Both read function_def; blocking reads the call graph stage 0
    # derives through the odd names.
    analyses = [:blocking, :structure]
    incremental = Graph.incremental(db, analyses)

    for analysis <- analyses do
      assert {:ok, _} = incremental[analysis]
    end

    assert incremental == Graph.fresh(paths, analyses)

    {:ok, %{outputs: %{"call_edge.facts" => digest}}} =
      Argus.Graph.Solve.stage(db, {:test, :stage0})

    {:ok, rows} = Argus.Souffle.Solve.rows(db.blob, "call_edge.facts", digest)
    names = List.flatten(rows)

    assert Enum.any?(names, &String.contains?(&1, "tab\there"))
  end
end
