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
  """
  @spec input_relations(Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def input_relations(rules_path, opts \\ []) do
    case Keyword.get(opts, :souffle_bin, find_souffle()) do
      nil ->
        {:error, :souffle_not_found}

      bin ->
        args = ["--show=transformed-ram", rules_path]

        case System.cmd(bin, args, stderr_to_stdout: false) do
          {output, 0} -> {:ok, parse_ram_inputs(output)}
          {output, code} -> {:error, {:souffle_error, code, output}}
        end
    end
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
            # OS pid + VM-unique integer: see Argus.Analysis.create_work_dir/0
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

    task = Task.async(fn -> System.cmd(bin, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {_output, 0}} ->
        parse_output(output_dir)

      {:ok, {output, exit_code}} ->
        {:error, {:souffle_error, exit_code, output}}

      nil ->
        {:error, :souffle_timeout}
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
            rows =
              content
              |> String.trim()
              |> String.split("\n", trim: true)
              |> Enum.map(&String.split(&1, "\t"))

            {:cont, {:ok, Map.put(acc, relation, rows)}}

          {:error, reason} ->
            {:halt, {:error, {:read_failed, path, reason}}}
        end
      end)
    end
  end
end
