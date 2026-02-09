defmodule Argus.Extract do
  @moduledoc """
  Orchestrates parallel fact extraction from BEAM modules.

  Resolves modules to `.beam` file paths, disassembles them in parallel,
  runs normalization and emission per module, then merges all per-module
  facts into unified `.facts` files (tab-separated, one file per relation).
  """

  alias Argus.Emitter

  @type extract_opts :: [
          concurrency: pos_integer(),
          extractors: [module()]
        ]

  @doc """
  Extracts facts from the given modules and writes `.facts` files to `output_dir`.

  Modules can be atoms (resolved via `:code.which/1`) or string paths to
  `.beam` files. Returns `{:ok, output_dir}` or `{:error, reason}`.
  """
  @spec run(modules :: [atom() | String.t()], output_dir :: Path.t(), extract_opts()) ::
          {:ok, Path.t()} | {:error, term()}
  def run(modules, output_dir, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    extractors = Keyword.get(opts, :extractors, [])

    with :ok <- File.mkdir_p(output_dir),
         {:ok, paths} <- resolve_modules(modules) do
      merged =
        paths
        |> Task.async_stream(
          fn path -> extract_module(path, extractors) end,
          max_concurrency: concurrency,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce(%{}, fn
          {:ok, {:ok, module_facts}}, acc ->
            merge_facts(acc, module_facts)

          {:ok, {:error, reason}}, _acc ->
            throw({:extraction_error, reason})

          {:exit, reason}, _acc ->
            throw({:extraction_error, reason})
        end)

      write_facts(merged, output_dir)
      {:ok, output_dir}
    end
  catch
    {:extraction_error, reason} -> {:error, reason}
  end

  @doc """
  Extracts facts from the given modules and returns them as a map
  without writing to disk.
  """
  @spec extract(modules :: [atom() | String.t()], extract_opts()) ::
          {:ok, Emitter.facts()} | {:error, term()}
  def extract(modules, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    extractors = Keyword.get(opts, :extractors, [])

    with {:ok, paths} <- resolve_modules(modules) do
      merged =
        paths
        |> Task.async_stream(
          fn path -> extract_module(path, extractors) end,
          max_concurrency: concurrency,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce(%{}, fn
          {:ok, {:ok, module_facts}}, acc ->
            merge_facts(acc, module_facts)

          {:ok, {:error, reason}}, _acc ->
            throw({:extraction_error, reason})

          {:exit, reason}, _acc ->
            throw({:extraction_error, reason})
        end)

      {:ok, merged}
    end
  catch
    {:extraction_error, reason} -> {:error, reason}
  end

  # ── Module resolution ──────────────────────────────────────────────

  defp resolve_modules(modules) do
    results =
      Enum.map(modules, fn
        path when is_binary(path) ->
          if File.exists?(path), do: {:ok, path}, else: {:error, {:not_found, path}}

        module when is_atom(module) ->
          case :code.which(module) do
            :non_existing -> {:error, {:not_found, module}}
            :cover_compiled -> {:error, {:cover_compiled, module}}
            path when is_list(path) -> {:ok, List.to_string(path)}
          end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, path} -> path end)}
      error -> error
    end
  end

  # ── Per-module extraction ──────────────────────────────────────────

  defp extract_module(path, extractors) do
    case BeamSpy.BeamFile.disassemble(path) do
      {:ok, data} ->
        base_facts =
          Emitter.emit_module(
            data.module,
            data.exports,
            fetch_imports(path),
            data.attributes,
            data.functions
          )

        # Run domain extractors and merge their facts.
        extractor_facts =
          Enum.reduce(extractors, %{}, fn extractor, acc ->
            merge_facts(acc, extractor.extract(data))
          end)

        {:ok, merge_facts(base_facts, extractor_facts)}

      {:error, _} = error ->
        error
    end
  end

  defp fetch_imports(path) do
    case BeamSpy.BeamFile.read_imports(path) do
      {:ok, imports} -> imports
      {:error, _} -> []
    end
  end

  # ── Fact merging ───────────────────────────────────────────────────

  defp merge_facts(left, right) do
    Map.merge(left, right, fn _key, l, r -> l ++ r end)
  end

  # ── .facts file I/O ────────────────────────────────────────────────

  @doc """
  Writes a facts map to tab-separated `.facts` files in the given directory.

  One file per relation, named `<relation>.facts`. Each line is a
  tab-separated row of values.
  """
  @spec write_facts(Emitter.facts(), Path.t()) :: :ok
  def write_facts(facts, output_dir) do
    Enum.each(facts, fn {relation, rows} ->
      path = Path.join(output_dir, "#{relation}.facts")

      content =
        rows
        |> Enum.reverse()
        |> Enum.map_join("\n", fn row -> Enum.join(row, "\t") end)

      File.write!(path, content <> "\n")
    end)
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
