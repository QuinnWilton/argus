defmodule Scry.AnalysisSpecsTest do
  @moduledoc """
  A module's extraction carries the specs of the remote functions it
  calls, read off the code path (`spec_return(_, _, "installed")`). When
  the callee is one of the project's own modules, those rows describe
  another module's beam, so the caller's memo must not outlive the
  callee: removing the callee re-extracts its callers, and a fresh batch
  extraction of what remains is what the graph then holds. A callee kept
  out of analysis by `ignore: [modules: ...]` is still on the code path:
  changing its spec re-extracts its callers too. So is argus, whose
  beams the environment digest leaves out: a caller of argus's code
  re-extracts when argus's code moves, and no other module does.
  """

  # The probe's ebin goes on the code path, and its modules are loaded
  # and purged: VM-wide.
  use ExUnit.Case, async: false

  alias Scry.Test.{Graph, QueryLog}

  @moduletag :tmp_dir

  @callee ScrySpecProbe.Callee
  @caller ScrySpecProbe.Caller
  @argus_caller ScrySpecProbe.ArgusCaller

  setup %{tmp_dir: dir} do
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    compile_probe!(dir, ebin, ":ok")

    # As in a Mix project: the compiled ebin is on the code path, which
    # is where extraction reads a remote callee's specs from.
    Code.prepend_path(ebin)

    on_exit(fn ->
      Code.delete_path(ebin)

      for module <- [@callee, @caller, @argus_caller],
          do: :code.purge(module) && :code.delete(module)
    end)

    paths = %{
      @callee => Path.join(ebin, "Elixir.ScrySpecProbe.Callee.beam"),
      @caller => Path.join(ebin, "Elixir.ScrySpecProbe.Caller.beam")
    }

    %{paths: paths}
  end

  # The callee's spec says `returns`; the caller calls it.
  defp compile_probe!(dir, ebin, returns) do
    compile_source!(dir, ebin, "probe.ex", """
    defmodule #{inspect(@callee)} do
      @spec put(term()) :: #{returns}
      def put(_x), do: :ok
    end

    defmodule #{inspect(@caller)} do
      def run(x), do: #{inspect(@callee)}.put(x)
    end
    """)
  end

  defp compile_source!(dir, ebin, name, code) do
    source = Path.join(dir, name)
    File.write!(source, code)

    # Specs are read from debug info, which `mix test` turns off.
    previous = Code.compiler_options(debug_info: true)

    try do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        {:ok, modules, _warnings} =
          Kernel.ParallelCompiler.compile_to_path([source], ebin, return_diagnostics: true)

        for module <- modules, do: :code.purge(module) && :code.delete(module)
      end)
    after
      Code.compiler_options(previous)
    end
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

  test "an ignored callee's spec change reaches its callers", %{paths: paths, tmp_dir: dir} do
    # Analyzed: the caller. Watched, not analyzed: the callee, as the
    # scanner leaves a module the `ignore` config matches.
    caller = Map.take(paths, [@caller])
    ignored = Map.take(paths, [@callee])
    db = Graph.new_db(caller)
    %{sources: sources} = Scry.Scanner.sync(db, caller, %{}, ignored)

    assert shapes_about_callee(Scry.Analysis.relation_facts(db, :spec_return)) ==
             ["constant", "total"]

    # The callee's spec changes; the scanner sees a new beam.
    compile_probe!(dir, Path.dirname(paths[@callee]), ":ok | {:error, term()}")
    %{ignored_moved?: true} = Scry.Scanner.sync(db, caller, sources, ignored)

    assert shapes_about_callee(Scry.Analysis.relation_facts(db, :spec_return)) == ["can_fail"]
  end

  test "a caller of argus re-extracts when argus's code moves, and no other module does", %{
    paths: paths,
    tmp_dir: dir
  } do
    ebin = Path.dirname(paths[@caller])

    compile_source!(dir, ebin, "argus_probe.ex", """
    defmodule #{inspect(@argus_caller)} do
      def run, do: Argus.Schema.version()
    end
    """)

    paths = Map.put(paths, @argus_caller, Path.join(ebin, "#{@argus_caller}.beam"))
    db = Graph.new_db(paths)

    try do
      for module <- Map.keys(paths), do: {:ok, _} = Scry.Analysis.module_extraction(db, module)

      # The specs of `Argus.Schema.version/0` were read off the code
      # path, where the environment digest does not look.
      assert argus_code_read?(db, @argus_caller)
      refute argus_code_read?(db, @caller)
      refute argus_code_read?(db, @callee)

      # This module runs after every async one: the log sees this graph
      # alone.
      log = QueryLog.start()

      try do
        :ok = Roux.Input.set(db, :argus_code, :all, "argus edited")

        for module <- Map.keys(paths),
            do: {:ok, _} = Scry.Analysis.module_extraction(db, module)

        assert QueryLog.executions(log, :module_extraction) == [@argus_caller]
      after
        QueryLog.detach(log)
      end
    after
      Roux.Database.shutdown(db)
    end
  end

  defp argus_code_read?(db, module) do
    {:ok, deps} = Roux.Memo.dependencies(db, {:module_extraction, module})
    {:input, :argus_code, :all} in deps
  end

  defp shapes_about_callee(rows) do
    rows |> installed_about_callee() |> Enum.map(&Enum.at(&1, 1)) |> Enum.sort()
  end
end
