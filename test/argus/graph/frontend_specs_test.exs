defmodule Argus.Graph.FrontendSpecsTest do
  @moduledoc """
  The removed-callee spec tracking over a frontend shaped like
  planchette's: no `:module_set` input, only the contract's queries. A
  caller that read a project callee's specs off the code path is
  extracted again when the callee leaves the frontend's `:module_map`.
  """

  # The probe's ebin goes on the code path, and its modules are loaded
  # and purged: VM-wide.
  use ExUnit.Case, async: false

  alias Roux.Input

  @moduletag :tmp_dir

  @callee ScryFrontendSpecProbe.Callee
  @caller ScryFrontendSpecProbe.Caller

  defmodule MapFrontend do
    @moduledoc false
    # Per-module beam paths, and the analyzed modules as a list: removing
    # a module moves the map without touching another module's beam.
    use Roux.Query

    alias Roux.Runtime

    definput(:probe_beam, durability: :medium)
    definput(:probe_modules, durability: :medium)
    definput(:env_fingerprint, durability: :high)

    defquery :module_beam, key: module, returns: {:ok, binary()} | :external do
      case Runtime.input(db, :probe_beam, module) do
        nil -> :external
        path -> {:ok, File.read!(path)}
      end
    end

    defquery :module_map, key: :all, returns: %{optional(module()) => String.t()} do
      Map.new(Runtime.input!(db, :probe_modules, :all), &{&1, "#{inspect(&1)}.ex"})
    end

    defquery :file_of, key: module, returns: String.t() | :external do
      Map.get(Runtime.query(db, :module_map, :all), module, :external)
    end
  end

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

    # The frontend's build output on the code path, where extraction
    # reads a remote callee's specs from (`mix compile.planchette`).
    Code.prepend_path(ebin)

    on_exit(fn ->
      Code.delete_path(ebin)
      for module <- [@callee, @caller], do: :code.purge(module) && :code.delete(module)
    end)

    db = Roux.Database.new()
    :ok = Roux.Lang.register_module(db, MapFrontend)
    :ok = Roux.Lang.register_module(db, Argus.Graph)
    :ok = Input.set(db, :env_fingerprint, :all, %{test: 1})

    for module <- [@callee, @caller] do
      :ok = Input.set(db, :probe_beam, module, Path.join(ebin, "#{module}.beam"))
    end

    :ok = Input.set(db, :probe_modules, :all, [@callee, @caller])

    %{db: db, ebin: ebin}
  end

  defp installed_about_callee(rows) do
    for [func, _shape, "installed"] = row <- rows,
        String.starts_with?(func, inspect(@callee) <> ":"),
        do: row
  end

  test "a callee leaving the module map re-extracts its callers", %{db: db, ebin: ebin} do
    assert installed_about_callee(Argus.Graph.relation_facts(db, :spec_return)) != []

    # The callee leaves the project and the code path; the caller's beam
    # is untouched.
    File.rm!(Path.join(ebin, "#{@callee}.beam"))
    :code.purge(@callee)
    :code.delete(@callee)
    :ok = Roux.GC.mark_input_removed(db, :probe_beam, @callee)
    :ok = Input.set(db, :probe_modules, :all, [@caller])

    assert installed_about_callee(Argus.Graph.relation_facts(db, :spec_return)) == []
  end
end
