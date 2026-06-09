defmodule Argus.Pipeline do
  @moduledoc """
  Orchestrates parallel fact extraction from BEAM modules.

  The pipeline runs in stages:

      modules → Disassemble → Emit (Layer 1) + Extractors (Layer 2) → write .facts

  - `Argus.Pipeline.Disassemble` resolves module names to `.beam` paths and
    reads BEAM files into normalized module data.
  - `Argus.Pipeline.Emit` produces base bytecode facts from each module.
  - User-supplied extractors implementing `Argus.Extractor` produce
    domain-specific Layer 2 facts.
  - `run/3` writes the merged facts to `.facts` files (one per relation,
    tab-separated). `extract/2` returns the merged facts in memory.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Pipeline.{Disassemble, Emit}

  @type extract_opts :: [
          concurrency: pos_integer(),
          extractors: [module()],
          timeout: timeout(),
          trace_imprecision: boolean(),
          format: :raw | :typed
        ]

  @default_timeout 120_000

  @doc """
  Extracts facts from the given modules and writes `.facts` files to `output_dir`.

  Modules can be atoms (resolved via `:code.which/1`) or string paths to
  `.beam` files. Returns `{:ok, output_dir}` or `{:error, reason}`.
  """
  @spec run(modules :: [atom() | String.t()], output_dir :: Path.t(), extract_opts()) ::
          {:ok, Path.t()} | {:error, term()}
  def run(modules, output_dir, opts \\ []) do
    with :ok <- File.mkdir_p(output_dir),
         {:ok, merged} <- extract(modules, opts),
         :ok <- write_facts(merged, output_dir) do
      {:ok, output_dir}
    end
  end

  @doc """
  Extracts facts from the given modules and returns them as a map
  without writing to disk.

  With `format: :typed`, rows are decoded against the schema via
  `Argus.Facts.decode/1` (field-name-keyed maps, integers, `Argus.InstrId`
  structs) instead of the raw string lists that `.facts` files use.
  """
  @spec extract(modules :: [atom() | String.t()], extract_opts()) ::
          {:ok, Emit.facts() | Argus.Facts.t()} | {:error, term()}
  def extract(modules, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    extractors = Keyword.get(opts, :extractors, [])
    task_timeout = Keyword.get(opts, :timeout, @default_timeout)
    trace_imprecision = Keyword.get(opts, :trace_imprecision, false)
    format = Keyword.get(opts, :format, :raw)

    with {:ok, paths} <- Disassemble.resolve_paths(modules) do
      merged =
        paths
        |> Task.async_stream(
          fn path -> extract_module(path, extractors, trace_imprecision) end,
          max_concurrency: concurrency,
          ordered: false,
          timeout: task_timeout
        )
        |> Enum.reduce(%{}, fn
          {:ok, {:ok, module_facts}}, acc ->
            merge_facts(acc, module_facts)

          {:ok, {:error, reason}}, _acc ->
            throw({:extraction_error, reason})

          {:exit, reason}, _acc ->
            throw({:extraction_error, reason})
        end)

      case format do
        :raw -> {:ok, merged}
        :typed -> {:ok, Argus.Facts.decode(merged)}
      end
    end
  catch
    {:extraction_error, reason} -> {:error, reason}
  end

  # Per-module extraction: disassemble, emit Layer 1 facts, run Layer 2
  # extractors, merge. Enables imprecision tracing in the worker process
  # when requested — the flag lives in the worker's process dictionary,
  # which is naturally scoped to this Task.async_stream worker, and the
  # try/after guarantees the flag is cleared before the worker returns
  # to the async pool.
  defp extract_module(path, extractors, trace_imprecision) do
    if trace_imprecision, do: Helpers.enable_tracing()

    try do
      with {:ok, data} <- Disassemble.disassemble_path(path) do
        base_facts =
          Emit.emit_module(
            data.module,
            data.exports,
            data.imports,
            data.attributes,
            data.functions
          )

        extractor_facts =
          Enum.reduce(extractors, %{}, fn extractor, acc ->
            merge_facts(acc, extractor.extract(data))
          end)

        {:ok, merge_facts(base_facts, extractor_facts)}
      end
    after
      if trace_imprecision, do: Helpers.disable_tracing()
    end
  end

  defp merge_facts(left, right) do
    Map.merge(left, right, fn _key, l, r -> r ++ l end)
  end

  # ── .facts file I/O ────────────────────────────────────────────────

  @spec write_facts(Emit.facts(), Path.t()) :: :ok | {:error, term()}
  defp write_facts(facts, output_dir) do
    # Create empty files for all known relations so Souffle never fails
    # on missing .input files.
    init_result =
      Enum.reduce_while(Argus.Schema.names(), :ok, fn name, :ok ->
        path = Path.join(output_dir, "#{name}.facts")

        if File.exists?(path) do
          {:cont, :ok}
        else
          case File.write(path, "") do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:write_failed, path, reason}}}
          end
        end
      end)

    case init_result do
      :ok ->
        Enum.reduce_while(facts, :ok, fn {relation, rows}, :ok ->
          path = Path.join(output_dir, "#{relation}.facts")

          content =
            rows
            |> Enum.reverse()
            |> Enum.map_join("\n", fn row -> Enum.join(row, "\t") end)

          case File.write(path, content <> "\n") do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:write_failed, path, reason}}}
          end
        end)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Reads a `.facts` file and returns rows as lists of strings.
  """
  @spec read_facts(Path.t()) :: {:ok, [[String.t()]]} | {:error, term()}
  def read_facts(path) do
    case File.read(path) do
      {:ok, content} ->
        rows =
          content
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.map(&String.split(&1, "\t"))

        {:ok, rows}

      {:error, _} = error ->
        error
    end
  end
end
