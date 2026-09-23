defmodule Scry.AnalysisSpecsTest do
  @moduledoc """
  A module's extraction carries the specs of the remote functions it
  calls, read off the code path (`spec_return(_, _, "installed")`). When
  the callee is one of the project's own modules, those rows describe
  another module's beam, so the caller's memo must not outlive the
  callee: removing the callee re-extracts its callers, and a fresh batch
  extraction of what remains is what the graph then holds.
  """

  use ExUnit.Case, async: false

  alias Scry.Test.Graph

  @moduletag :tmp_dir

  @callee ScrySpecProbe.Callee
  @caller ScrySpecProbe.Caller

  setup %{tmp_dir: dir} do
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    source = Path.join(dir, "probe.ex")

    File.write!(source, """
    defmodule #{inspect(@callee)} do
      @spec put(term()) :: :ok
      def put(_x), do: :ok
    end

    defmodule #{inspect(@caller)} do
      def run(x), do: #{inspect(@callee)}.put(x)
    end
    """)

    # Specs are read from debug info, which `mix test` turns off.
    previous = Code.compiler_options(debug_info: true)

    try do
      {:ok, _modules, _warnings} =
        Kernel.ParallelCompiler.compile_to_path([source], ebin, return_diagnostics: true)
    after
      Code.compiler_options(previous)
    end

    # As in a Mix project: the compiled ebin is on the code path, which
    # is where extraction reads a remote callee's specs from.
    Code.prepend_path(ebin)

    on_exit(fn ->
      Code.delete_path(ebin)
      for module <- [@callee, @caller], do: :code.purge(module) && :code.delete(module)
    end)

    paths = %{
      @callee => Path.join(ebin, "Elixir.ScrySpecProbe.Callee.beam"),
      @caller => Path.join(ebin, "Elixir.ScrySpecProbe.Caller.beam")
    }

    %{paths: paths}
  end

  defp installed_about_callee(rows) do
    for [func, _shape, "installed"] = row <- rows,
        String.starts_with?(func, inspect(@callee) <> ":"),
        do: row
  end

  test "removing a callee drops the specs its callers read from it", %{paths: paths} do
    db = Graph.new_db(paths)

    assert installed_about_callee(Scry.Analysis.relation_facts(db, :spec_return)) != []

    # The callee leaves the project and the code path.
    File.rm!(paths[@callee])
    :code.purge(@callee)
    :code.delete(@callee)
    Graph.sync!(db, Map.delete(paths, @callee))

    # A fresh extraction of the caller alone reads no spec for it...
    {:ok, fresh} =
      Argus.Pipeline.extract([File.read!(paths[@caller])], extractors: [Argus.Extractors.Specs])

    assert installed_about_callee(Map.get(fresh, :spec_return, [])) == []

    # ...and neither does the graph.
    assert installed_about_callee(Scry.Analysis.relation_facts(db, :spec_return)) == []
  end
end
