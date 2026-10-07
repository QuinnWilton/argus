defmodule Argus.FlowLog.Program do
  @moduledoc """
  A Datalog program as FlowLog compiles it: its manifest (`inspect/2`),
  and the engine that hosts it (`engine/3`).

  The manifest is what the program reads and writes, as FlowLog resolves
  them after pruning every relation no output reaches:

      %{inputs: [%{name:, file:, columns:}], outputs: [%{name:, file:, columns:}]}

  It is asked of the tool (`argus-flowlog-tool inspect`), which runs
  FlowLog's front end and planner and no Rust compiler, so it is quick;
  a program the tool rejects (it does not compile, or argus cannot host
  it: an input not declared `mutable`, a column that is neither a symbol
  nor a number) is `{:error, {:flowlog_program, path, diagnostic}}`, the
  diagnostic rendered against the program's source.

  An engine is built once per program digest and profile (`t:profile/0`)
  and kept under the toolchain's `engines/<digest>/`: its executable
  (`engine`, or `engine-quick` unoptimized), and the manifest it was
  built from. Building generates the program's crate from the engine
  template in a scratch directory, compiles it into the toolchain's
  shared target directory, and installs the executable by rename; the
  crate is removed whatever happens. A program's digest must name
  everything its engine is built from (`Argus.Graph.Programs`): a stale
  engine answers `hello` with the digest it was built for, and
  `Argus.FlowLog.Engine` refuses it.
  """

  require Logger

  alias Argus.FlowLog.Prebuilt
  alias Argus.FlowLog.Toolchain

  @typedoc "One input or output relation of a program."
  @type relation :: %{name: String.t(), file: String.t(), columns: [String.t()]}

  @typedoc """
  What a program reads and writes, and (from `inspect/2`) every relation
  with its columns' names and types, for a debugging probe to name.
  """
  @type manifest :: %{
          required(:inputs) => [relation()],
          required(:outputs) => [relation()],
          optional(:relations) => [%{name: String.t(), columns: [map()]}]
        }

  @doc """
  The program's manifest, asked of the toolchain's tool (`inspect`).
  """
  @spec inspect(Toolchain.t(), Path.t()) :: {:ok, manifest()} | {:error, term()}
  def inspect(%Toolchain{} = toolchain, rules_path) do
    path = Path.expand(rules_path)
    run_tool(toolchain, ["inspect", path], path)
  end

  defp run_tool(toolchain, args, path) do
    case System.cmd(Toolchain.tool(toolchain), args, stderr_to_stdout: false) do
      {out, status} when status in [0, 1] ->
        case decode(out) do
          {:ok, %{"ok" => true} = manifest} ->
            {:ok,
             %{
               inputs: relations(manifest["inputs"]),
               outputs: relations(manifest["outputs"]),
               relations:
                 for(
                   %{"name" => name, "columns" => columns} <- Map.get(manifest, "relations", []),
                   do: %{name: name, columns: columns}
                 )
             }}

          {:ok, %{"ok" => false, "diagnostic" => diagnostic}} ->
            {:error, {:flowlog_program, path, diagnostic}}

          _ ->
            {:error, {:flowlog_tool, status, out}}
        end

      {out, status} ->
        {:error, {:flowlog_tool, status, out}}
    end
  end

  defp decode(out) do
    {:ok, out |> String.trim() |> :json.decode()}
  rescue
    _ -> :error
  end

  defp relations(list) do
    for %{"name" => name, "file" => file, "columns" => columns} <- list,
        do: %{name: name, file: file, columns: columns}
  end

  @typedoc """
  How an engine is compiled. `:release` is optimized: every program argus
  ships is built so, and every other one unless `ARGUS_FLOWLOG_BUILD_PROFILE`
  says `quick`. `:quick` leaves the program's own code unoptimized: it
  compiles about three times faster and solves about three and a half
  times slower, which suits a program solved over a handful of rows.
  """
  @type profile :: :release | :quick

  @typedoc "A program to build: its path, its digest, and its profile."
  @type build :: {Path.t(), String.t(), profile()}

  @doc """
  The profile the engine of the program at `rules_path` is built with:
  `:release` for argus's own programs, and otherwise what
  `ARGUS_FLOWLOG_BUILD_PROFILE` says (`release`, the default, or
  `quick`). Raises `ArgumentError` naming the variable when it says
  anything else.
  """
  @spec profile(Path.t()) :: profile()
  def profile(rules_path) do
    if shipped?(Path.expand(rules_path)), do: :release, else: requested_profile()
  end

  defp requested_profile do
    case System.get_env("ARGUS_FLOWLOG_BUILD_PROFILE", "") do
      value when value in ["", "release"] ->
        :release

      "quick" ->
        :quick

      other ->
        raise ArgumentError,
              "ARGUS_FLOWLOG_BUILD_PROFILE is #{inspect(other)}; it takes release (the default) " <>
                "or quick"
    end
  end

  @doc """
  The engine executable for the program at `rules_path`, whose digest is
  `digest`: installed, or built now (`engines/3`, as a batch of one).
  """
  @spec engine(Toolchain.t(), Path.t(), String.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def engine(%Toolchain{} = toolchain, rules_path, digest, opts \\ []) do
    with :ok <- engines(toolchain, [{rules_path, digest}], opts),
         do: {:ok, installed(toolchain, digest, profile(rules_path))}
  end

  @doc """
  Installs the engine of each `{rules_path, digest}` not installed yet,
  building them together: one Cargo build whose binaries are the
  programs, which Cargo compiles side by side (one program's compile is
  mostly one thread's work). A program that fails to compile fails
  alone: the others are installed, and the first failure is returned.
  `opts`:

    * `:progress` — a function told of each build before it starts
      (default `Logger.info/1`), or `false`.

  Builds take turns in a VM (`Toolchain.locked/2`), and Cargo serializes
  builds into the toolchain's target directory across VMs.
  """
  @spec engines(Toolchain.t(), [{Path.t(), String.t()}], keyword()) :: :ok | {:error, term()}
  def engines(%Toolchain{} = toolchain, programs, opts \\ []) do
    case missing(toolchain, programs) do
      [] -> :ok
      todo -> first_failure(build(toolchain, [{todo, opts}]), todo)
    end
  end

  defp first_failure(results, programs) do
    Enum.find_value(programs, :ok, fn program ->
      case Map.fetch!(results, key(program)) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  defp missing(toolchain, programs) do
    programs
    |> Enum.map(fn {path, digest} ->
      path = Path.expand(path)
      {path, digest, profile(path)}
    end)
    |> Enum.uniq_by(&key/1)
    |> Enum.reject(fn {_path, digest, profile} -> installed(toolchain, digest, profile) end)
  end

  @doc """
  Where the engine for `digest` built with `profile` (default `:release`)
  is installed, whether or not it is.
  """
  @spec executable(Toolchain.t(), String.t(), profile()) :: Path.t()
  def executable(toolchain, digest, profile \\ :release)

  def executable(toolchain, digest, :release),
    do: Path.join([Toolchain.engines(toolchain), digest, "engine"])

  def executable(toolchain, digest, :quick),
    do: Path.join([Toolchain.engines(toolchain), digest, "engine-quick"])

  @doc """
  The installed engine for `digest` that a program built with `profile`
  runs, or `nil`. A `:quick` program runs the release engine when one is
  installed: it solves the same, and faster. A `:release` program never
  runs a quick one.
  """
  @spec installed(Toolchain.t(), String.t(), profile()) :: Path.t() | nil
  def installed(toolchain, digest, profile) do
    usable = if profile == :quick, do: [:release, :quick], else: [:release]

    Enum.find_value(usable, fn candidate ->
      path = executable(toolchain, digest, candidate)
      if File.regular?(path), do: path
    end)
  end

  @doc false
  # Every program the requests name (each with the options of the
  # request that asked for it), built under the VM's build lock. Each
  # program's outcome, by its digest and profile.
  @spec build(Toolchain.t(), [{[build()], keyword()}]) ::
          %{{String.t(), profile()} => :ok | {:error, term()}}
  def build(%Toolchain{} = toolchain, requests) do
    Toolchain.locked(:build, fn ->
      {done, todo} =
        requests
        |> Enum.flat_map(fn {programs, opts} -> Enum.map(programs, &{&1, opts}) end)
        |> Enum.uniq_by(fn {program, _opts} -> key(program) end)
        |> Enum.split_with(fn {{_path, digest, profile}, _opts} ->
          installed(toolchain, digest, profile)
        end)

      done
      |> Map.new(fn {program, _opts} -> {key(program), :ok} end)
      |> Map.merge(build_missing(toolchain, todo))
    end)
  end

  defp key({_path, digest, profile}), do: {digest, profile}

  # The built-in programs a release's bundle holds an engine for are
  # installed from it; the rest are compiled, which a toolchain without
  # Rust cannot do.
  defp build_missing(_toolchain, []), do: %{}

  defp build_missing(toolchain, programs) do
    {installed, rest} = from_bundle(toolchain, programs)

    cond do
      rest == [] ->
        installed

      toolchain.kind == :prebuilt ->
        Map.merge(
          installed,
          Map.new(rest, fn {{path, _, _} = program, _opts} ->
            {key(program), {:error, {:needs_rust, display(path)}}}
          end)
        )

      true ->
        Map.merge(installed, compile_all(toolchain, rest))
    end
  end

  defp from_bundle(toolchain, programs) do
    {shipped, others} = Enum.split_with(programs, fn {{path, _, _}, _opts} -> shipped?(path) end)
    opts = with [{_program, opts} | _] <- shipped, do: opts

    case if(shipped == [], do: {:error, :none}, else: Prebuilt.fetch(opts)) do
      {:ok, bundle} ->
        {bundled, unbundled} =
          Enum.split_with(shipped, fn {{_path, digest, _profile}, _opts} ->
            match?({:ok, _, _}, Prebuilt.engine(bundle, digest))
          end)

        installed =
          Map.new(bundled, fn {{_path, digest, :release} = program, _opts} ->
            {:ok, engine, manifest} = Prebuilt.engine(bundle, digest)
            dir = Path.join(Toolchain.engines(toolchain), digest)
            File.mkdir_p!(dir)
            Toolchain.install(manifest, Path.join(dir, "manifest.json"))
            {key(program), Toolchain.install(engine, executable(toolchain, digest))}
          end)

        {installed, unbundled ++ others}

      {:error, reason} ->
        if reason not in [:disabled, :none] and shipped != [],
          do:
            Logger.warning(
              "argus: building the FlowLog engines instead: " <>
                Prebuilt.describe(reason)
            )

        {%{}, programs}
    end
  end

  defp shipped?(path), do: String.starts_with?(path, Argus.Dl.shipped() <> "/")

  # One Cargo build per profile: a build compiles every binary with one.
  defp compile_all(toolchain, programs) do
    for {{path, _digest, profile}, opts} <- programs do
      Toolchain.announce(
        opts,
        "building the FlowLog engine for #{display(path)} (once per version of its rules" <>
          if(profile == :quick, do: ", unoptimized)", else: ")")
      )
    end

    programs
    |> Enum.map(fn {program, _opts} -> program end)
    |> Enum.group_by(fn {_path, _digest, profile} -> profile end)
    |> Enum.reduce(%{}, fn {profile, group}, acc ->
      Map.merge(acc, compile_profile(toolchain, profile, group))
    end)
  end

  defp compile_profile(toolchain, profile, programs) do
    crate =
      Path.join(
        Toolchain.tmp(toolchain),
        "crate-#{:os.getpid()}-#{System.unique_integer([:positive])}"
      )

    try do
      {generated, failed} = generate_all(toolchain, crate, programs)
      built = if generated == [], do: [], else: compile(toolchain, crate, profile, generated)
      Map.new(failed ++ built)
    after
      File.rm_rf(crate)
    end
  end

  # Each program's binary under `src/bin/<bin>/`: the host's sources
  # beside the program and glue the tool generates for it.
  defp generate_all(toolchain, crate, programs) do
    host = Path.join([Toolchain.src(toolchain), "engine", "src"])

    {generated, failed} =
      Enum.reduce(programs, {[], []}, fn {path, digest, _profile} = program,
                                         {generated, failed} ->
        bin = bin_name(digest)
        dir = Path.join([crate, "src", "bin", bin])
        File.mkdir_p!(dir)

        for file <- ["main.rs", "host.rs"],
            do: File.cp!(Path.join(host, file), Path.join(dir, file))

        case generate(toolchain, path, dir, digest) do
          {:ok, manifest} -> {[{program, bin, manifest} | generated], failed}
          {:error, _} = error -> {generated, [{key(program), error} | failed]}
        end
      end)

    {Enum.reverse(generated), Enum.reverse(failed)}
  end

  defp compile(toolchain, crate, profile, generated) do
    bins = Enum.map(generated, fn {_program, bin, _manifest} -> bin end)
    :ok = scaffold(toolchain, crate, bins)
    log = Toolchain.build_log(toolchain, batch_name(generated))

    case Toolchain.cargo_build(toolchain, crate, bins, log, {:engines, length(bins)}, profile) do
      :ok ->
        Enum.map(generated, &{key(elem(&1, 0)), install(toolchain, profile, &1)})

      {:error, {:build_failed, _what, log, tail}} ->
        # Built with --keep-going: what compiled is installed, and what
        # did not is a failure named by its program.
        Enum.map(generated, fn {{path, _, _} = program, bin, _manifest} = built ->
          if File.regular?(Toolchain.built(toolchain, bin, profile)),
            do: {key(program), install(toolchain, profile, built)},
            else: {key(program), {:error, {:build_failed, {:engine, display(path)}, log, tail}}}
        end)
    end
  end

  defp install(toolchain, profile, {{_path, digest, _profile}, bin, manifest}) do
    dir = Path.join(Toolchain.engines(toolchain), digest)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.json"), :json.encode(manifest_json(manifest)))
    built = Toolchain.built(toolchain, bin, profile)
    Toolchain.install(built, executable(toolchain, digest, profile))
    File.rm(built)
    :ok
  end

  defp display(path), do: Path.relative_to(path, Argus.Dl.root())

  defp bin_name(digest), do: "engine-#{binary_part(digest, 0, min(16, byte_size(digest)))}"

  # A build's log is named for the programs it built.
  defp batch_name([{{_path, digest, _profile}, _bin, _manifest}]), do: digest

  defp batch_name(generated) do
    :crypto.hash(
      :sha256,
      Enum.map(generated, fn {{_path, digest, _}, _bin, _manifest} -> digest end)
    )
    |> Base.encode16(case: :lower)
  end

  # The template's manifest and lockfile, its one binary replaced by the
  # programs' (`autobins` off: only the binaries named here are built).
  # Binaries named for their program's digest never overwrite each other
  # in the shared target directory.
  defp scaffold(toolchain, crate, bins) do
    template = Path.join(Toolchain.src(toolchain), "engine")
    binary = ~s([[bin]]\nname = "argus-flowlog-engine"\npath = "src/main.rs"\n)
    source = template |> Path.join("Cargo.toml") |> File.read!()

    unless String.contains?(source, binary) and String.contains?(source, "publish = false\n"),
      do: raise("the engine template's Cargo.toml no longer names its binary as argus expects")

    targets =
      Enum.map_join(bins, "\n", &~s([[bin]]\nname = "#{&1}"\npath = "src/bin/#{&1}/main.rs"\n))

    manifest =
      source
      |> String.replace("publish = false\n", "publish = false\nautobins = false\n")
      |> String.replace(binary, targets)

    File.write!(Path.join(crate, "Cargo.toml"), manifest)
    File.cp!(Path.join(template, "Cargo.lock"), Path.join(crate, "Cargo.lock"))
    :ok
  end

  defp generate(toolchain, rules_path, dir, digest) do
    run_tool(toolchain, ["generate", rules_path, dir, digest], rules_path)
  end

  defp manifest_json(%{inputs: inputs, outputs: outputs} = _manifest) do
    %{
      "inputs" => Enum.map(inputs, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end)),
      "outputs" => Enum.map(outputs, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
    }
  end
end
