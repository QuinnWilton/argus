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

  alias Argus.Dataflow
  alias Argus.Extractor.Helpers
  alias Argus.InstrId
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

  Modules can be atoms (resolved via `:code.which/1`), string paths to
  `.beam` files, or raw beam data binaries. Returns `{:ok, output_dir}`
  or `{:error, reason}`.
  """
  @spec run(
          modules :: [Disassemble.module_input()],
          output_dir :: Path.t(),
          extract_opts()
        ) ::
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
  @spec extract(modules :: [Disassemble.module_input()], extract_opts()) ::
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
          # Ordered so that extracting the same modules twice produces the
          # same value. With `ordered: false` the reduce sees workers in
          # completion order, and `merge_facts/2` concatenates, so row order
          # varied run to run — measured at 8 distinct results from 8
          # extractions of the same 40 modules. Souffle has set semantics
          # and never noticed, but any consumer that memoizes, hashes or
          # diffs facts did: planchette had to sort every relation itself to
          # get value equality. Ordering costs a little buffering (a worker
          # that finishes early is held until its predecessors do) and buys
          # a property the whole workspace was otherwise re-deriving.
          ordered: true,
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
            data.functions,
            data.line_table
          )

        extractor_facts =
          Enum.reduce(extractors, %{}, fn extractor, acc ->
            merge_facts(acc, extractor.extract(data))
          end)

        {:ok,
         base_facts
         |> merge_facts(extractor_facts)
         |> merge_facts(derive_def_use(base_facts))
         |> merge_facts(derive_conditional_calls(base_facts))}
      end
    after
      if trace_imprecision, do: Helpers.disable_tracing()
    end
  end

  # Reaching definitions, derived per module rather than over the merged
  # program. `Argus.Dataflow` never produces an edge crossing a function, so
  # deriving here is equivalent to deriving once at the end — and it keeps
  # the result per-module, which is what lets an incremental consumer reuse
  # it for every module the edit did not touch.
  #
  # The output is smaller than `instruction`, which it is derived from:
  # 25,409 edges against 88,658 instructions on oban, 137,170 against
  # 243,350 on keila. It is still keyed on positional instruction IDs, so a
  # body edit churns that function's edges — which is why only the analyses
  # that need value flow should declare it, and why it is emitted rather
  # than folded into an existing relation.
  defp derive_def_use(base_facts) do
    edges = base_facts |> Argus.Facts.decode() |> Dataflow.def_use_edges()

    case Enum.map(edges, fn {d, u} -> [InstrId.format(d), InstrId.format(u)] end) do
      [] -> %{}
      rows -> %{def_use: rows}
    end
  rescue
    # A module whose facts cannot be decoded should not take the whole
    # extraction down; it loses value-flow edges and keeps everything else.
    _ -> %{}
  end

  # Call instructions whose block is control-dependent on a branch in the
  # same function — the calls that only happen on some paths. Positional
  # like def_use (keyed on instruction IDs), and derived here for the same
  # reason: the post-dominator tree exists in Argus.Cfg, and the
  # alternative is reconstructing it from `instruction`/`branch`/`jump`
  # rows in Datalog on every solve.
  defp derive_conditional_calls(base_facts) do
    typed = Argus.Facts.decode(base_facts)
    cfgs = Argus.Cfg.build(typed)

    call_ids =
      for relation <- [:local_call, :remote_call, :bif_call],
          [id | _] <- Map.get(base_facts, relation, []),
          do: id

    conditional_blocks =
      Map.new(cfgs, fn {key, fun} ->
        {key, fun |> Argus.Cfg.Function.control_deps() |> Map.keys() |> MapSet.new()}
      end)

    rows =
      for id <- call_ids,
          {:ok, %InstrId{func: name, arity: arity, idx: idx}} <- [InstrId.parse(id)],
          fun = Map.get(cfgs, {name, arity}),
          fun != nil,
          block = Argus.Cfg.Function.block_at(fun, idx),
          block != nil,
          MapSet.member?(conditional_blocks[{name, arity}], block.id),
          do: [id]

    case rows do
      [] -> %{}
      rows -> %{conditional_call: Enum.sort(rows)}
    end
  rescue
    _ -> %{}
  end

  defp merge_facts(left, right) do
    Map.merge(left, right, fn _key, l, r -> r ++ l end)
  end

  # ── .facts file I/O ────────────────────────────────────────────────

  @doc """
  Writes extracted facts to `.facts` files in `output_dir` (one
  tab-separated file per relation).

  Empty files are materialized for every schema relation so Souffle never
  fails on a missing `.input` file. Callers that merge per-module fact
  maps themselves (rather than going through `run/3`) can use this to
  produce a Souffle-ready facts directory from in-memory facts.

  Expects raw-format facts (string rows, as returned by `extract/2` with
  the default `format: :raw`). The directory must already exist.
  """
  @spec write_facts(Emit.facts(), Path.t()) :: :ok | {:error, term()}
  def write_facts(facts, output_dir) do
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

          # An explicitly-empty relation must produce a zero-byte file, not
          # a lone newline: Souffle reads the blank line as a tuple with
          # missing columns and aborts with "Values missing in line 1".
          # Callers that build a fact map by merging never hit this (an
          # empty relation is simply absent), but one that projects a
          # fixed relation list does.
          content =
            case rows do
              [] ->
                ""

              rows ->
                rows
                |> Enum.reverse()
                |> Enum.map_join("\n", fn row -> Enum.join(row, "\t") end)
                |> Kernel.<>("\n")
            end

          case File.write(path, content) do
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
