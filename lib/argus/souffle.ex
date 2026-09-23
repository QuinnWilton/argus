defmodule Argus.Souffle do
  @moduledoc """
  Souffle execution via shell-out to the `souffle` command-line tool.

  Invokes `souffle -F <facts_dir> -D <output_dir> <rules.dl>` and parses
  the tab-separated output files back into lists of string rows.


  """

  @type result :: %{String.t() => [[String.t()]]}

  # 5 minutes default timeout for Souffle execution.
  @default_souffle_timeout 300_000

  @doc """
  Runs Souffle against `facts_dir` using `rules_path` and returns the
  derived relations.

  ## Options

  - `:souffle_bin` — path to the souffle binary (default: auto-detect on PATH)
  - `:souffle_timeout` — milliseconds before the run is aborted (default: 5 min)
  - `:output_dir` — where Souffle should write `.csv` outputs (default: tmpdir)
  """
  @spec run(Path.t(), Path.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(facts_dir, rules_path, opts \\ []) do
    souffle_bin = Keyword.get(opts, :souffle_bin, find_souffle())

    case souffle_bin do
      nil ->
        {:error, :souffle_not_found}

      bin ->
        timeout = Keyword.get(opts, :souffle_timeout, @default_souffle_timeout)

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

  For a program shipped under argus's `priv/dl`, the answer is memoized
  for the life of the VM: it depends on nothing but the Datalog sources
  and the solver, so the memo is versioned by a digest of every file
  under `priv/dl` and the solver binary's identity, and an edited rule
  or a swapped solver misses. A program anywhere else is resolved on
  every call.
  """
  @spec input_relations(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def input_relations(rules_path, opts \\ []) do
    case Keyword.get(opts, :souffle_bin, find_souffle()) do
      nil ->
        {:error, :souffle_not_found}

      bin ->
        case shipped_program_key(rules_path, bin) do
          nil -> resolve_input_relations(bin, rules_path)
          key -> memoized(key, fn -> resolve_input_relations(bin, rules_path) end)
        end
    end
  end

  defp resolve_input_relations(bin, rules_path) do
    args = ["--show=transformed-ram", rules_path]

    case System.cmd(bin, args, stderr_to_stdout: false) do
      {output, 0} -> {:ok, parse_ram_inputs(output)}
      {output, code} -> {:error, {:souffle_error, code, output}}
    end
  end

  # `{key, version}` for a program under priv/dl, nil for any other. The
  # persistent term is keyed by the program alone and carries the version
  # it was resolved under: an edit overwrites one term instead of leaking
  # a new one per digest.
  defp shipped_program_key(rules_path, bin) do
    with dir when is_list(dir) <- :code.priv_dir(:panoptes),
         dl_dir = Path.join(List.to_string(dir), "dl"),
         path = Path.expand(rules_path),
         true <- String.starts_with?(path, dl_dir <> "/"),
         {:ok, %File.Stat{mtime: mtime, size: size}} <- File.stat(bin) do
      {{__MODULE__, :input_relations, path}, {directory_digest(dl_dir), bin, mtime, size}}
    else
      _ -> nil
    end
  end

  # Only a resolved answer is kept: a failure is reported every time it
  # happens, and never served from the memo.
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

  # Every regular file under `dir`, by relative path and content.
  defp directory_digest(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn file, hash ->
      hash
      |> :crypto.hash_update(Path.relative_to(file, dir))
      |> :crypto.hash_update(File.read!(file))
    end)
    |> :crypto.hash_final()
  end

  # RAM IO directives look like:
  #   IO <name> (IO="file",...,operation="input",...)
  # Outputs carry operation="output"; only inputs are fact files we must
  # supply.
  defp parse_ram_inputs(output) do
    ~r/IO\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+\((?<attrs>[^)]*)\)/
    |> Regex.scan(output, capture: :all)
    |> Enum.filter(fn [_full, _name, attrs] -> attrs =~ ~s(operation="input") end)
    |> Enum.map(fn [_full, name, _attrs] -> name end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp find_souffle do
    case System.find_executable("souffle") do
      nil -> nil
      path -> path
    end
  end

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
            {:cont, {:ok, Map.put(acc, relation, Argus.Tsv.decode(content))}}

          {:error, reason} ->
            {:halt, {:error, {:read_failed, path, reason}}}
        end
      end)
    end
  end
end
