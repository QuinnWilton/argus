defmodule Argus.FlowLog do
  @moduledoc """
  argus's Datalog engine: FlowLog (https://github.com/flowlog-rs/flowlog),
  which compiles a program into a Differential Dataflow executable that
  keeps its results up to date as its facts change.

  Every program argus solves runs in an engine of its own
  (`Argus.FlowLog.Engine`), built once per program digest from the
  toolchain argus carries (`Argus.FlowLog.Toolchain`,
  `Argus.FlowLog.Program`). The query graph keeps engines between
  solves (`Argus.FlowLog.Pool`, `Argus.FlowLog.Solve`), so a solve over
  facts that moved a little is a small epoch of an engine that already
  holds the rest. `run/3` here is the one-shot form: one engine, one
  commit of a facts directory, and the engine stopped.

  ## Programs

  A program is FlowLog's Soufflé-style dialect. argus hosts one whose
  every `.input` relation is declared `mutable` (an engine deletes the
  rows a relation loses) and whose inputs and outputs have `symbol` and
  `number` columns only; the tool says why it rejects another
  (`Argus.FlowLog.Program.inspect/2`).
  """

  alias Argus.FlowLog.Engine
  alias Argus.FlowLog.Native
  alias Argus.FlowLog.Program
  alias Argus.FlowLog.Toolchain

  @type result :: %{String.t() => [[String.t()]]}

  # 5 minutes: how long a commit may run by default.
  @default_timeout 300_000

  @doc "How long a commit may run when `:timeout` does not say: five minutes."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc """
  The dataflow worker threads an engine runs: `ARGUS_FLOWLOG_WORKERS`,
  else the smaller of four and the VM's schedulers.
  """
  @spec default_workers() :: pos_integer()
  def default_workers do
    case Integer.parse(System.get_env("ARGUS_FLOWLOG_WORKERS", "")) do
      {n, ""} when n > 0 -> n
      _ -> min(4, System.schedulers_online())
    end
  end

  @doc """
  Whether argus can solve: the toolchain is built, or can be (Rust is
  installed and new enough).
  """
  @spec available?() :: boolean()
  def available? do
    match?({:ok, _}, Toolchain.rust())
  end

  @doc "The message to show a user when `available?/0` is false."
  @spec not_found_message() :: String.t()
  def not_found_message do
    case Toolchain.rust() do
      {:ok, _} -> "the FlowLog toolchain is available"
      {:error, reason} -> Toolchain.describe(reason)
    end
  end

  @doc """
  A one-line description of an engine error, for a report.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:flowlog_unavailable, reason}), do: Toolchain.describe(reason)
  def describe_error({:build_failed, _, _, _} = reason), do: Toolchain.describe(reason)
  def describe_error({:needs_rust, _} = reason), do: Toolchain.describe(reason)

  def describe_error({:flowlog_program, path, diagnostic}),
    do: "#{path} does not compile:\n#{diagnostic}"

  def describe_error(:flowlog_timeout), do: "the engine did not finish within the solve's timeout"

  def describe_error({:flowlog_error, kind, message}),
    do: "the engine refused the commit (#{kind}): #{message}"

  def describe_error({:flowlog_engine_exit, status, log}),
    do: "the engine exited with status #{status}#{if log != "", do: ":\n" <> log, else: ""}"

  def describe_error({:flowlog_engine_down, reason}), do: "the engine stopped: #{inspect(reason)}"

  def describe_error({:flowlog_stale_engine, exe, wanted, got}),
    do: "the engine #{exe} was built for program #{got}, not #{wanted}; remove it to rebuild"

  def describe_error(reason), do: inspect(reason)

  @doc """
  The digest naming a program as a solve of it reads it, and the engine
  built from it: its files as `Argus.Dl.Program.declared_digest/2` counts
  them for the relations it loads, and the toolchain's sources (which pin
  FlowLog's revision, and with it what every rule means).
  """
  @spec program_digest(Path.t(), [String.t()] | :all) :: String.t()
  def program_digest(rules_path, relations) do
    declared = Argus.Dl.Program.declared_digest(rules_path, relations)

    :crypto.hash(:sha256, :erlang.term_to_binary({declared, Native.digest()}))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The program's manifest (`Argus.FlowLog.Program.inspect/2`), memoized
  for the VM by the program's files and the toolchain.
  """
  @spec manifest(Path.t(), keyword()) :: {:ok, Program.manifest()} | {:error, term()}
  def manifest(rules_path, opts \\ []) do
    path = Path.expand(rules_path)

    with {:ok, toolchain} <- toolchain(opts) do
      digest = Argus.Dl.Program.program_digest(path)
      key = {__MODULE__, :manifest, path}

      case :persistent_term.get(key, nil) do
        {^digest, toolchain_key, manifest} when toolchain_key == toolchain.key ->
          {:ok, manifest}

        _ ->
          with {:ok, manifest} <- Program.inspect(toolchain, path) do
            :persistent_term.put(key, {digest, toolchain.key, manifest})
            {:ok, manifest}
          end
      end
    end
  end

  @doc "The relations a program reads, by name, sorted."
  @spec input_relations(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def input_relations(rules_path, opts \\ []) do
    with {:ok, manifest} <- manifest(rules_path, opts) do
      {:ok, manifest.inputs |> Enum.map(& &1.name) |> Enum.sort()}
    end
  end

  @doc "The files a program reads its inputs from in a facts directory, sorted."
  @spec input_files(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def input_files(rules_path, opts \\ []) do
    with {:ok, manifest} <- manifest(rules_path, opts) do
      {:ok, manifest.inputs |> Enum.map(& &1.file) |> Enum.sort()}
    end
  end

  @doc "The toolchain, as `{:ok, toolchain}` or `{:error, {:flowlog_unavailable, reason}}`."
  @spec toolchain(keyword()) :: {:ok, Toolchain.t()} | {:error, term()}
  def toolchain(opts \\ []) do
    case Toolchain.ensure(opts) do
      {:ok, toolchain} -> {:ok, toolchain}
      {:error, {:build_failed, _, _, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:flowlog_unavailable, reason}}
    end
  end

  @doc """
  The engine executable for a program: built when missing. Returns the
  toolchain, the program's digest, its manifest and the executable.
  """
  @spec engine(Path.t(), keyword()) ::
          {:ok,
           %{
             toolchain: Toolchain.t(),
             digest: String.t(),
             manifest: Program.manifest(),
             executable: Path.t()
           }}
          | {:error, term()}
  def engine(rules_path, opts \\ []) do
    path = Path.expand(rules_path)

    with {:ok, toolchain} <- toolchain(opts),
         {:ok, manifest} <- manifest(path, opts),
         digest = program_digest(path, Enum.map(manifest.inputs, & &1.name)),
         {:ok, executable} <- Program.engine(toolchain, path, digest, opts) do
      {:ok, %{toolchain: toolchain, digest: digest, manifest: manifest, executable: executable}}
    end
  end

  @doc """
  argus's own programs: the two shared stages' (three files: the
  bounded points-to program runs in the exact one's place) and every
  built-in analysis's.
  """
  @spec builtin_programs() :: [Path.t()]
  def builtin_programs do
    stages = [
      Argus.Analysis.stage0_rules_path(),
      Argus.Analysis.points_to_rules_path(),
      Argus.Analysis.points_to_bounded_rules_path()
    ]

    analyses =
      for mod <- Argus.Analysis.builtin_analysis_modules(),
          {:ok, path} = Argus.Analysis.Catalog.rules_path(mod.name()),
          do: path

    Enum.uniq(stages ++ analyses)
  end

  @doc """
  Builds the toolchain and the engine of every program in `programs`
  (default: `builtin_programs/0`) that is not built yet, in one build
  that compiles them side by side (`Argus.FlowLog.Program.engines/3`):
  what a first run on a machine would otherwise build one at a time as
  its analyses ask. A program that fails to build leaves the others
  built, and is the error returned.

  `opts` take `:progress` (`Argus.FlowLog.Program.engines/3`).
  """
  @spec prebuild([Path.t()], keyword()) :: :ok | {:error, term()}
  def prebuild(programs \\ builtin_programs(), opts \\ []) do
    with {:ok, toolchain} <- toolchain(opts),
         {:ok, digests} <- digests(programs, opts) do
      Program.engines(toolchain, digests, opts)
    end
  end

  defp digests(programs, opts) do
    Enum.reduce_while(programs, {:ok, []}, fn path, {:ok, acc} ->
      path = Path.expand(path)

      case manifest(path, opts) do
        {:ok, manifest} ->
          digest = program_digest(path, Enum.map(manifest.inputs, & &1.name))
          {:cont, {:ok, acc ++ [{path, digest}]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  @doc """
  Solves the program at `rules_path` over the facts in `facts_dir`, in an
  engine of its own, and returns every `.csv` output's rows by its file's
  name without the extension, each relation's rows sorted
  (`decode_output/1`). An output the program names `.facts` (a stage's,
  read by other programs as an input) is written to `:output_dir` only.

  Every input the program reads must have its file in `facts_dir`: a
  missing one is an `Argus.MissingRelationError`, never an empty
  relation.

  ## Options

    * `:timeout` — milliseconds the solve may run (default five minutes);
    * `:output_dir` — a directory to write the outputs into as well, each
      under the file name the program gives it;
    * `:workers` — dataflow worker threads (default `default_workers/0`).
  """
  @spec run(Path.t(), Path.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(facts_dir, rules_path, opts \\ []) do
    with {:ok, built} <- engine(rules_path, opts),
         {:ok, inputs} <- facts_inputs(facts_dir, built.manifest) do
      out = scratch_dir()

      try do
        with {:ok, engine} <- start(built, opts) do
          try do
            timeout = Keyword.get(opts, :timeout, @default_timeout)

            with {:ok, _report} <- Engine.commit(engine, out, inputs, %{}, timeout),
                 {:ok, result} <- read_outputs(out, built.manifest) do
              copy_outputs(out, built.manifest, Keyword.get(opts, :output_dir))
              {:ok, result}
            end
          after
            Engine.stop(engine)
          end
        end
      after
        File.rm_rf(out)
      end
    end
  end

  defp start(built, opts) do
    Engine.start_link(
      executable: built.executable,
      digest: built.digest,
      workers: Keyword.get(opts, :workers, default_workers()),
      log: Toolchain.run_log(built.toolchain, built.digest)
    )
  catch
    :exit, reason -> {:error, reason}
  end

  defp facts_inputs(facts_dir, manifest) do
    Enum.reduce_while(manifest.inputs, {:ok, %{}}, fn %{name: name, file: file}, {:ok, acc} ->
      path = Path.join(facts_dir, file)

      if File.regular?(path) do
        {:cont, {:ok, Map.put(acc, name, path)}}
      else
        {:halt,
         {:error, %Argus.MissingRelationError{relation: name, path: path, reason: :enoent}}}
      end
    end)
  end

  # The outputs a caller reads back: every `.csv` one. A program names an
  # output `.facts` to hand it to another program as an input (a stage's
  # call graph), and those stay files.
  defp read_outputs(dir, manifest) do
    manifest.outputs
    |> Enum.filter(&(Path.extname(&1.file) == ".csv"))
    |> Enum.reduce_while({:ok, %{}}, fn %{name: name, file: file}, {:ok, acc} ->
      path = Path.join(dir, file)

      case File.read(path) do
        {:ok, content} ->
          {:cont, {:ok, Map.put(acc, Path.rootname(file), decode_output(content))}}

        {:error, reason} ->
          {:halt,
           {:error, %Argus.MissingRelationError{relation: name, path: path, reason: reason}}}
      end
    end)
  end

  defp copy_outputs(_dir, _manifest, nil), do: :ok

  defp copy_outputs(dir, manifest, output_dir) do
    for %{file: file} <- manifest.outputs do
      File.cp!(Path.join(dir, file), Path.join(output_dir, file))
    end

    :ok
  end

  defp scratch_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "argus_flowlog_#{:os.getpid()}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf(dir)
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  The rows of one output file an engine wrote, sorted. An engine writes
  them sorted by their bytes already; decoding (`Argus.Tsv`) unescapes
  each field, and the sort is Elixir's, the order every caller reads.
  """
  @spec decode_output(binary()) :: [[String.t()]]
  def decode_output(content), do: content |> Argus.Tsv.decode() |> Enum.sort()
end
