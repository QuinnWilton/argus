defmodule Argus.Graph.FrontendSpecsTest do
  @moduledoc """
  The removed-callee spec tracking over a frontend of its own, shaped
  like planchette's: the contract's queries answered from inputs of its
  own (`Argus.Graph.open/1`'s `frontend:`). A caller that read a project
  callee's specs off the code path is extracted again when the callee
  leaves, as long as the frontend sets the `beam` input of each beam it
  puts on the code path.
  """

  # The probe's ebin goes on the code path, and its modules are loaded
  # and purged: VM-wide.
  use ExUnit.Case, async: false

  alias Roux.Input

  @moduletag :tmp_dir

  @callee ArgusFrontendSpecProbe.Callee
  @caller ArgusFrontendSpecProbe.Caller

  defmodule MapFrontend do
    @moduledoc false
    # Beams by module, and the analyzed modules as a list: removing a
    # module moves the list without touching another module's beam.
    use Roux.Query

    alias Roux.Runtime

    definput(:probe_beam, durability: :medium)

    defquery :module_beam, key: module do
      case Runtime.input(db, :probe_beam, module, default: nil) do
        nil -> :external
        path -> {:ok, %{path: path, hash: Argus.Graph.hash(File.read!(path))}}
      end
    end

    defquery :module_name, key: module do
      module
    end

    defquery :module_source, key: module do
      "#{inspect(module)}.ex"
    end

    defquery :program_modules, key: program do
      db |> Runtime.input(:program, program, default: []) |> Map.new(&{&1, &1})
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
      for module <- [@callee, @caller], do: unload(module)
    end)

    session = Argus.Graph.open(frontend: MapFrontend, store: Roux.Blob.temporary())
    db = session.db
    _moved = Argus.Graph.set_environment(db)
    :ok = Argus.Graph.set_priors(db, :test, :off)

    for module <- [@callee, @caller] do
      path = Path.join(ebin, "#{module}.beam")
      :ok = Input.set(db, :probe_beam, module, path)
      # The contract: each beam put on the code path is a `beam` input.
      {key, value} = Argus.Graph.beam_input(path)
      :ok = Input.set(db, :beam, key, value)
    end

    :ok = Input.set(db, :program, :test, [@callee, @caller])
    on_exit(fn -> Roux.Blob.destroy(session.blob) end)

    %{db: db, ebin: ebin}
  end

  defp installed_about_callee(rows) do
    for [func, _shape, "installed"] = row <- rows,
        String.starts_with?(func, inspect(@callee) <> ":"),
        do: row
  end

  test "a callee leaving the program re-extracts its callers", %{db: db, ebin: ebin} do
    assert installed_about_callee(spec_return(db)) != []

    # The callee leaves the project and the code path; the caller's beam
    # is untouched.
    path = Path.join(ebin, "#{@callee}.beam")
    File.rm!(path)
    :code.purge(@callee)
    :code.delete(@callee)
    :ok = Roux.GC.mark_input_removed(db, :probe_beam, @callee)
    :ok = Roux.GC.mark_input_removed(db, :beam, Path.expand(path))
    :ok = Input.set(db, :program, :test, [@caller])

    assert installed_about_callee(spec_return(db)) == []
  end

  defp spec_return(db), do: Argus.Graph.Relations.rows(db, :test, :spec_return)

  # Out of the VM whether or not it has old code: `:code.purge/1` answers
  # false for a module with none, and a `&&` after it would leave the
  # module loaded, where `:code.which/1` finds it for the next test.
  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end
end
