defmodule Argus.Souffle do
  @moduledoc """
  Souffle execution via shell-out to the `souffle` command-line tool.

  Invokes `souffle -F <facts_dir> -D <output_dir> <rules.dl>` and parses
  the tab-separated output files back into lists of string rows.


  """

  alias Argus.Souffle.Program

  @type result :: %{String.t() => [[String.t()]]}

  # 5 minutes default timeout for Souffle execution.
  @default_souffle_timeout 300_000

  @doc """
  Runs Souffle against `facts_dir` using `rules_path` and returns the
  derived relations, each relation's rows sorted (`decode_output/1`).

  ## Options

  - `:souffle_bin` — path to the souffle binary (default: auto-detect on PATH)
  - `:souffle_timeout` — milliseconds before the run is aborted (default: 5 min)
  - `:output_dir` — where Souffle should write `.csv` outputs (default: tmpdir)

  Every call solves: the graph keeps its solves in the blob store
  (`Argus.Souffle.Solve`). `:solve_cache`, the batch pipeline's store of
  kept solves, went with it in 0.20 and raises.
  """
  @spec run(Path.t(), Path.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(facts_dir, rules_path, opts \\ []) do
    if Keyword.has_key?(opts, :solve_cache) do
      raise ArgumentError,
            ":solve_cache: kept solves live in the blob store since 0.20 " <>
              "(Argus.Souffle.Solve, through Argus.run_analyses/2 or the query graph)"
    end

    case Keyword.get(opts, :souffle_bin, find_souffle()) do
      nil ->
        {:error, :souffle_not_found}

      bin ->
        timeout = Keyword.get(opts, :souffle_timeout, @default_souffle_timeout)
        run_uncached(bin, facts_dir, rules_path, timeout, opts)
    end
  end

  defp run_uncached(bin, facts_dir, rules_path, timeout, opts) do
    case resolve_output_dir(opts) do
      {:ok, output_dir} ->
        try do
          run_souffle(bin, facts_dir, rules_path, output_dir, timeout)
        after
          # A directory chosen by the caller is theirs to keep (stage 0
          # writes its outputs into the facts directory this way); one
          # this module made is gone once the CSVs are read.
          unless Keyword.has_key?(opts, :output_dir), do: File.rm_rf(output_dir)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns true if the `souffle` binary is available on the system PATH.
  """
  @spec available?() :: boolean()
  def available? do
    find_souffle() != nil
  end

  @doc """
  The message to show a user when `available?/0` is false.
  """
  @spec not_found_message() :: String.t()
  def not_found_message do
    "souffle binary not found on PATH. Install Souffle " <>
      "(https://souffle-lang.github.io/install) to run the analyses."
  end

  @doc """
  The relations a rules program reads, as Souffle resolves them.

  Compiles the program only as far as the transformed RAM — no facts are
  read and no solve runs — and returns the relations it would load.

  The RAM is the right oracle here. Reading `.input` out of the source
  over-approximates (declared-but-unused relations survive in the AST and
  are pruned later), and resolving `.include` by hand under-approximates
  (Souffle resolves includes relative to the including file, so a naive
  walker misses transitively included declarations). Only the RAM says
  what will actually be opened.

  The answer is memoized for the life of the VM, keyed by the program
  with its includes (`Argus.Souffle.Program.declared_digest/2`: every
  declaration, but not the comments, of a file of declarations alone)
  and the solver's version (`version/1`): an edited rule or
  declaration, or a swapped solver, misses. The query graph keeps what
  a program reads in its store (`Argus.Graph.Programs`).
  """
  @spec input_relations(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def input_relations(rules_path, opts \\ []) do
    with {:ok, inputs} <- inputs(rules_path, opts) do
      {:ok, inputs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @doc """
  The files `input_relations/2`'s relations are read from, in a facts
  directory: `<relation>.facts`, unless the program names another file.
  """
  @spec input_files(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def input_files(rules_path, opts \\ []) do
    with {:ok, inputs} <- inputs(rules_path, opts) do
      {:ok, inputs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp inputs(rules_path, opts) do
    case Keyword.get(opts, :souffle_bin, find_souffle()) do
      nil ->
        {:error, :souffle_not_found}

      bin ->
        path = Path.expand(rules_path)

        if File.regular?(path) do
          # By the declarations, not their comments: a schema edit that
          # moves only prose resolves nothing again.
          version = {Program.declared_digest(path, :all), bin, version(bin)}

          memoized({{__MODULE__, :inputs, path}, version}, fn ->
            resolve_inputs(bin, path)
          end)
        else
          resolve_inputs(bin, path)
        end
    end
  end

  defp resolve_inputs(bin, rules_path) do
    with {:ok, output} <- transformed_ram(bin, rules_path) do
      {:ok, parse_ram_inputs(output)}
    end
  end

  defp transformed_ram(bin, rules_path) do
    case System.cmd(bin, ["--show=transformed-ram", rules_path], stderr_to_stdout: false) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:souffle_error, code, output}}
    end
  end

  @doc """
  What a program reads and writes, as Souffle resolves them from the
  transformed RAM (see `input_relations/2`), asked of `bin` every call:
  `{:ok, %{inputs: [{relation, file}], outputs: [{relation, file}]}}`,
  each file named as the program opens it (`<relation>.facts` for an
  input and `<relation>.csv` for an output, unless the program names
  another). An output to the terminal is no file and is not listed.
  """
  @spec ram_io(String.t(), Path.t()) ::
          {:ok, %{inputs: [{String.t(), String.t()}], outputs: [{String.t(), String.t()}]}}
          | {:error, term()}
  def ram_io(bin, rules_path) do
    with {:ok, output} <- transformed_ram(bin, Path.expand(rules_path)) do
      {:ok, %{inputs: parse_ram_inputs(output), outputs: parse_ram_outputs(output)}}
    end
  end

  defp parse_ram_outputs(output) do
    ~r/IO\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+\((?<attrs>[^)]*)\)/
    |> Regex.scan(output, capture: :all)
    |> Enum.filter(fn [_full, _name, attrs] ->
      attrs =~ ~s(operation="output") and attrs =~ ~s(IO="file")
    end)
    |> Enum.map(fn [_full, name, attrs] ->
      case Regex.run(~r/filename="([^"]*)"/, attrs) do
        [_, file] -> {name, Path.basename(file)}
        nil -> {name, name <> ".csv"}
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "How long a solve may run when `:souffle_timeout` does not say: five minutes."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_souffle_timeout

  @doc """
  Runs `bin` over the facts in `facts_dir` with the program at
  `rules_path`, writing its outputs into `output_dir`, which must
  exist: `:ok`, or `{:error, {:souffle_error, status, output}}`, or
  `{:error, :souffle_timeout}` when it did not finish within `timeout`
  (the solver is stopped). The outputs are left for the caller to read.
  """
  @spec execute_into(String.t(), Path.t(), Path.t(), Path.t(), timeout()) ::
          :ok | {:error, term()}
  def execute_into(bin, facts_dir, rules_path, output_dir, timeout) do
    case execute(bin, ["-F", facts_dir, "-D", output_dir, rules_path], timeout) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, exit_code}} -> {:error, {:souffle_error, exit_code, output}}
      :timeout -> {:error, :souffle_timeout}
    end
  end

  @doc """
  The solver's `--version` output, once per VM for each binary (asked
  again when the binary is replaced: `Argus.Souffle.Program.stamped/2`),
  or `"unrunnable"`: the part of a key that names the solver wherever
  it is installed.
  """
  @spec version(String.t()) :: String.t()
  def version(bin) do
    Program.stamped({__MODULE__, :version, bin}, fn ->
      version =
        try do
          {out, _status} = System.cmd(bin, ["--version"], stderr_to_stdout: true)
          out
        rescue
          _ -> "unrunnable"
        end

      {[bin], version}
    end)
  end

  # Only a resolved answer is kept: a failure is reported every time it
  # happens, and never served from the memo. The persistent term is
  # keyed by the program alone and carries the version it was resolved
  # under: an edit overwrites one term instead of leaking one per digest.
  defp memoized({key, version}, resolve) do
    case :persistent_term.get(key, nil) do
      {^version, result} ->
        result

      _ ->
        case resolve.() do
          {:ok, _} = ok ->
            :persistent_term.put(key, {version, ok})
            ok

          {:error, _} = error ->
            error
        end
    end
  end

  # RAM IO directives look like:
  #   IO <name> (IO="file",...,operation="input",...)
  # Outputs carry operation="output"; only inputs are fact files we must
  # supply. An input read from another file than `<name>.facts` names it
  # in a `filename` attribute.
  defp parse_ram_inputs(output) do
    ~r/IO\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+\((?<attrs>[^)]*)\)/
    |> Regex.scan(output, capture: :all)
    |> Enum.filter(fn [_full, _name, attrs] -> attrs =~ ~s(operation="input") end)
    |> Enum.map(fn [_full, name, attrs] ->
      case Regex.run(~r/filename="([^"]*)"/, attrs) do
        [_, file] -> {name, file}
        nil -> {name, name <> ".facts"}
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The `souffle` on `PATH`, or nil. Looked up once per VM for each value
  of `PATH`: a lookup stats every directory on it, and every solve asks.
  """
  @spec executable() :: String.t() | nil
  def executable do
    key = {__MODULE__, :executable, System.get_env("PATH")}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        found = System.find_executable("souffle")
        :persistent_term.put(key, found)
        found

      found ->
        found
    end
  end

  defp find_souffle, do: executable()

  defp resolve_output_dir(opts) do
    case Keyword.fetch(opts, :output_dir) do
      {:ok, dir} ->
        {:ok, dir}

      :error ->
        case System.tmp_dir() do
          nil ->
            {:error, :no_tmp_dir}

          tmp ->
            # OS pid + VM-unique integer: see Argus.Analysis.Extraction's create_work_dir/0
            # — unique_integer alone collides across concurrent VMs.
            dir =
              Path.join(
                tmp,
                "argus_souffle_#{:os.getpid()}_#{System.unique_integer([:positive])}"
              )

            # Remove any stale output from a dead VM that had the same OS
            # pid and picked the same integer, then create a fresh directory.
            File.rm_rf(dir)

            case File.mkdir_p(dir) do
              :ok -> {:ok, dir}
              {:error, reason} -> {:error, {:mkdir_failed, reason}}
            end
        end
    end
  end

  defp run_souffle(bin, facts_dir, rules_path, output_dir, timeout) do
    args = [
      "-F",
      facts_dir,
      "-D",
      output_dir,
      rules_path
    ]

    case execute(bin, args, timeout) do
      {:ok, {_output, 0}} ->
        parse_output(output_dir)

      {:ok, {output, exit_code}} ->
        {:error, {:souffle_error, exit_code, output}}

      :timeout ->
        {:error, :souffle_timeout}
    end
  end

  # Souffle as a port this process owns, and an OS process that never
  # outlives the port. Closing a port does not stop the program behind it:
  # `System.cmd/3` under a `Task.shutdown/1` left a timed-out solve running
  # to completion, a core and hundreds of megabytes apiece, and so did a
  # caller that died or a VM that halted (an interrupted `mix compile`).
  #
  # So the solver runs under a small `/bin/sh` reaper holding the port's
  # stdin: the solver is started in the background, and the reaper reads
  # stdin until it closes, then kills the solver. The VM never writes to
  # it, so stdin closes exactly when the port does — at the deadline
  # (`Port.close/1` below), when the calling process dies (its ports close
  # with it), and when the VM exits by any means, a SIGKILL included. When
  # the solver finishes on its own, its exit status is the reaper's.
  @reaper ~S"""
  exec 3<&0
  "$@" 0</dev/null &
  solver=$!
  { while read -r _ <&3; do :; done; kill -9 "$solver" 2>/dev/null; } &
  reaper=$!
  wait "$solver"
  status=$?
  kill "$reaper" 2>/dev/null
  exit "$status"
  """

  defp execute(bin, args, timeout) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", @reaper, "souffle" | [bin | args]]
      ])

    deadline = if timeout == :infinity, do: :infinity, else: now_ms() + timeout

    case collect(port, [], deadline) do
      {:ok, _} = done ->
        done

      :timeout ->
        close(port)
        :timeout
    end
  end

  defp collect(port, acc, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [acc | data], deadline)

      {^port, {:exit_status, status}} ->
        {:ok, {IO.iodata_to_binary(acc), status}}
    after
      remaining(deadline) ->
        :timeout
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - now_ms(), 0)

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Closing stdin is what stops the solver. The port may already be closed
  # by the solver's exit; its last messages are dropped so they do not
  # reach the caller's mailbox.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  after
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  @doc """
  The rows of one output file Souffle wrote, sorted.

  Souffle writes a relation in the order of its symbols' numbers, which
  is the order it met them in, and where it meets them first moves with
  its version: Souffle 2.4 and 2.5 write one relation's rows in
  different orders over the same facts. Sorted, an analysis's rows are
  a function of its input alone.
  """
  @spec decode_output(binary()) :: [[String.t()]]
  def decode_output(content), do: content |> Argus.Tsv.decode() |> Enum.sort()

  # The relations a solve wrote into a directory of its own: every
  # `.csv` there. Souffle writes a file for each relation the program
  # outputs, empty when it has no rows, and nothing else writes into the
  # directory, so the listing is every output.
  defp parse_output(output_dir) do
    with {:ok, files} <- File.ls(output_dir) do
      csv_files = Enum.filter(files, &String.ends_with?(&1, ".csv"))

      Enum.reduce_while(csv_files, {:ok, %{}}, fn filename, {:ok, acc} ->
        relation = String.trim_trailing(filename, ".csv")
        path = Path.join(output_dir, filename)

        case File.read(path) do
          {:ok, content} ->
            # Never trimmed: a symbol column may be empty, and trimming
            # the file would eat the tab that carries an empty last column
            # of the last row (or first column of the first).
            {:cont, {:ok, Map.put(acc, relation, decode_output(content))}}

          {:error, reason} ->
            {:halt, {:error, {:read_failed, path, reason}}}
        end
      end)
    end
  end
end
