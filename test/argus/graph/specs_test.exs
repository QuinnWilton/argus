defmodule Argus.Graph.SpecsTest do
  @moduledoc """
  A module's extraction carries the specs of the remote functions it
  calls, read off the code path (`spec_return(_, _, "installed")`), and
  depends on each module whose specs it read (`installed_specs`,
  `Argus.Graph.Reads`). When the callee is one of the project's own
  modules, those rows describe another module's beam, so the caller's
  facts must not outlive the callee: removing the callee re-extracts
  its callers, and a fresh extraction of what remains is what the graph
  then holds. A callee kept out of analysis by `ignore: [modules: ...]`
  is still on the code path: changing its spec re-extracts its callers
  too. A directory of the code path whose beams were rebuilt with no
  spec changed (argus's own, for a program that calls argus)
  re-extracts nothing.
  """

  # The probe's ebin goes on the code path, and its modules are loaded
  # and purged: VM-wide.
  use ExUnit.Case, async: false

  alias Argus.Test.Graph
  alias Roux.QueryLog

  @moduletag :tmp_dir

  @callee ArgusSpecProbe.Callee
  @caller ArgusSpecProbe.Caller
  @argus_caller ArgusSpecProbe.ArgusCaller

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
          do: unload(module)
    end)

    paths = %{
      @callee => Path.join(ebin, "Elixir.ArgusSpecProbe.Callee.beam"),
      @caller => Path.join(ebin, "Elixir.ArgusSpecProbe.Caller.beam")
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

        for module <- modules, do: unload(module)
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

  defp spec_return(db), do: Argus.Graph.Relations.rows(db, :test, :spec_return)

  test "removing a callee drops the specs its callers read from it", %{paths: paths} do
    db = Graph.new_db(paths)

    assert installed_about_callee(spec_return(db)) != []

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
    assert installed_about_callee(spec_return(db)) == []
  end

  test "an ignored callee's spec change reaches its callers", %{paths: paths, tmp_dir: dir} do
    # Analyzed: the caller. Watched, not analyzed: the callee, as the
    # driver syncs a module the `ignore` config matches: its beam is an
    # input, and it is in no program.
    db = Graph.new_db(Map.take(paths, [@caller]))
    watch!(db, paths[@callee])

    assert shapes_about_callee(spec_return(db)) == ["constant", "total"]

    # The callee's spec changes; its beam input moves.
    compile_probe!(dir, Path.dirname(paths[@callee]), ":ok | {:error, term()}")
    watch!(db, paths[@callee])

    assert shapes_about_callee(spec_return(db)) == ["can_fail"]
  end

  test "a rebuilt directory with no spec changed re-extracts nothing", %{
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
    argus = :panoptes |> :code.lib_dir() |> List.to_string() |> Path.join("ebin") |> Path.expand()

    try do
      for key <- Map.values(paths), do: {:ok, _} = Argus.Graph.Extraction.module_facts(db, key)

      # The specs of `Argus.Schema.version/0` were read off the code
      # path, from argus's own directory.
      assert read_specs?(db, paths[@argus_caller], Argus.Schema)
      refute read_specs?(db, paths[@caller], Argus.Schema)

      # This module runs after every async one: the log sees this graph
      # alone.
      log = QueryLog.start(db)

      try do
        :ok = Roux.Input.set(db, :app_code, argus, "argus rebuilt")

        for key <- Map.values(paths),
            do: {:ok, _} = Argus.Graph.Extraction.module_facts(db, key)

        assert :installed_specs
               |> then(&QueryLog.executions(log, &1))
               |> Enum.member?(Argus.Schema)

        assert QueryLog.executions(log, :module_facts) == []
      after
        QueryLog.stop(log)
      end
    after
      Roux.Database.shutdown(db)
    end
  end

  defp watch!(db, path) do
    {key, value} = Argus.Graph.beam_input(path)
    :ok = Roux.Input.set(db, :beam, key, value)
  end

  defp read_specs?(db, key, module) do
    {:ok, deps} = Roux.Memo.dependencies(db, {:module_facts, key})
    {:installed_specs, module} in deps
  end

  defp shapes_about_callee(rows) do
    rows |> installed_about_callee() |> Enum.map(&Enum.at(&1, 1)) |> Enum.sort()
  end

  # Out of the VM whether or not it has old code: `:code.purge/1` answers
  # false for a module with none, and a `&&` after it would leave the
  # module loaded, where `:code.which/1` finds it for the next test.
  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end
end
