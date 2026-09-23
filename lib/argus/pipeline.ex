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
  - `run/3` streams each module's facts to `.facts` files (one per
    relation, tab-separated) as extraction completes, so the program's
    fact set never exists in memory at once. `extract/2` returns the
    merged facts in memory.

  A module's failures stay with the module: an extractor that raises, or
  a module that outlives the per-module `:timeout`, is recorded as an
  `extraction_error` row (see `Argus.Schema`) and the run goes on over
  everything else. Only an input that cannot be read ends it with
  `{:error, reason}`.
  """

  alias Argus.Cfg
  alias Argus.Extractor.Helpers
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.{Disassemble, Emit, Writer}

  @type extract_opts :: [
          concurrency: pos_integer(),
          extractors: [module()],
          timeout: timeout(),
          trace_imprecision: boolean(),
          format: :raw | :typed | :interned,
          symbols: Argus.Symbols.t()
        ]

  @type run_opts :: [
          concurrency: pos_integer(),
          extractors: [module()],
          timeout: timeout(),
          trace_imprecision: boolean(),
          relations: :all | [atom()]
        ]

  @default_timeout 120_000

  # The Layer-1 relations the in-process passes read from a module's
  # decoded facts: `Argus.Cfg`, `Argus.Dataflow` and the extractors that
  # take `module_data.typed` (Dependence, ParamFlow, PidFlow). Decoding
  # every relation was a fifth of extraction time, most of it for
  # relations only Souffle reads.
  @typed_relations ~w(
    instruction next def use jump branch select_branch label_at bs_start
    try_start bif_call function_def function_entry tail_call remote_call
    local_call dynamic_call spawn_call
  )a

  @doc """
  The relations of a module's facts the pipeline decodes for the passes
  that run in the VM — `Argus.Cfg.build/1`, `Argus.Dataflow`, and an
  extractor reading `module_data.typed` — which is all `typed` holds. An
  extractor that reads another relation there adds it here;
  `Argus.Pipeline.TypedRelationsTest` fails when one's facts change with
  every relation decoded.
  """
  @spec typed_relations() :: [atom()]
  def typed_relations, do: @typed_relations

  @doc """
  Extracts facts from the given modules and writes `.facts` files to `output_dir`.

  Modules can be atoms (resolved via `:code.which/1`), string paths to
  `.beam` files, or raw beam data binaries. Returns `{:ok, output_dir}`
  or `{:error, reason}`.

  Every schema relation gets a file (Souffle fails on a missing `.input`
  file), but `relations:` limits which ones receive rows: the rest stay
  empty. `Argus.Analysis.extract_facts/3` uses it to leave out the
  relations that exist only for the in-process control-flow and dataflow
  passes (`Argus.Schema.in_process_only/0`), which no Souffle program
  reads and which are most of the fact volume.
  """
  @spec run(
          modules :: [Disassemble.module_input()],
          output_dir :: Path.t(),
          run_opts()
        ) ::
          {:ok, Path.t()} | {:error, term()}
  def run(modules, output_dir, opts \\ []) do
    written =
      case Keyword.get(opts, :relations, :all) do
        :all -> nil
        names -> MapSet.new(names)
      end

    with :ok <- File.mkdir_p(output_dir),
         :ok <- touch_relations(output_dir),
         {:ok, paths} <- Disassemble.resolve_paths(modules) do
      writer = Writer.new(output_dir, written)
      memo = new_memo()

      try do
        paths
        |> extract_stream(opts, memo, &Writer.encode(&1, written))
        |> Enum.reduce_while({:ok, writer}, fn
          {:ok, encoded}, {:ok, writer} ->
            case Writer.append_encoded(writer, encoded) do
              {:ok, writer} -> {:cont, {:ok, writer}}
              {:error, _} = error -> {:halt, error}
            end

          {:error, reason}, _ ->
            {:halt, {:error, reason}}
        end)
        |> case do
          {:ok, writer} -> with :ok <- Writer.close(writer), do: {:ok, output_dir}
          {:error, _} = error -> error
        end
      after
        Writer.close(writer)
        :ets.delete(memo)
      end
    end
  end

  @doc """
  Extracts facts from the given modules and returns them as a map
  without writing to disk.

  With `format: :typed`, rows are decoded against the schema via
  `Argus.Facts.decode/1` (field-name-keyed maps, integers, `Argus.InstrId`
  structs) instead of the raw string lists that `.facts` files use. With
  `format: :interned`, rows are tuples of `Argus.Symbols` ids interned in
  the worker that extracted them against the `symbols:` table the caller
  owns (`Argus.Facts.interned/0`); the caller keeps the table, and reads
  the rows back through `Argus.Facts.materialize/2` or `decode/2`.
  """
  @spec extract(modules :: [Disassemble.module_input()], extract_opts()) ::
          {:ok, Emit.facts() | Argus.Facts.t()} | {:error, term()}
  def extract(modules, opts \\ []) do
    format = Keyword.get(opts, :format, :raw)

    if format == :interned and not match?(%Argus.Symbols{}, opts[:symbols]) do
      raise ArgumentError, "format: :interned needs the symbols: table the ids refer to"
    end

    opts = if format == :interned, do: opts, else: Keyword.delete(opts, :symbols)

    with {:ok, paths} <- Disassemble.resolve_paths(modules) do
      memo = new_memo()
      symbols = Keyword.get(opts, :symbols)

      merged =
        try do
          paths
          |> extract_stream(opts, memo, &maybe_intern(&1, symbols))
          |> Enum.reduce(%{}, fn
            {:ok, module_facts}, acc -> merge_facts(acc, module_facts)
            {:error, reason}, _acc -> throw({:extraction_error, reason})
          end)
        after
          :ets.delete(memo)
        end

      case format do
        :raw -> {:ok, merged}
        :typed -> {:ok, Argus.Facts.decode(merged)}
        :interned -> {:ok, merged}
      end
    end
  catch
    {:extraction_error, reason} -> {:error, reason}
  end

  # One `{:ok, facts} | {:error, reason}` per module, in input order.
  #
  # Nothing a module does takes the caller down. The workers are linked to
  # the caller, so a raise that escaped one would exit the caller (scry's
  # compiler, a test process) before the stream could report it; every
  # step is therefore caught in the worker (`extract_module/4`), and a
  # worker that outlives the per-module timeout is killed on its own
  # (`on_timeout: :kill_task`) rather than failing the whole stream. Both
  # come back as an `extraction_error` row: what was lost is recorded
  # beside what was extracted, and the run goes on. Only an input that
  # cannot be read at all (`{:error, reason}` from disassembly) ends it.
  #
  # `shape` is what the worker does to a module's facts before they cross
  # to the caller, which takes them one module at a time in input order:
  # interning them (`extract/2`), or encoding them as the lines of their
  # files (`run/3`), so the caller only writes. Encoding in the caller
  # left the workers waiting on it: on the Phoenix stack writing the facts
  # took longer than extracting them at eight workers.
  defp extract_stream(paths, opts, memo, shape) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    extractors = Keyword.get(opts, :extractors, [])
    task_timeout = Keyword.get(opts, :timeout, @default_timeout)
    trace_imprecision = Keyword.get(opts, :trace_imprecision, false)

    paths
    |> Task.async_stream(
      fn path -> extract_module(path, extractors, trace_imprecision, shape, memo) end,
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
      timeout: task_timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Stream.map(fn
      {:ok, result} ->
        result

      {:exit, {path, :timeout}} ->
        reason = "extraction did not finish within #{task_timeout} ms"
        {:ok, shape.(lost_module(path, reason))}

      {:exit, {path, reason}} ->
        {:ok, shape.(lost_module(path, "extraction exited: #{one_line(inspect(reason))}"))}
    end)
  end

  # Per-module extraction: disassemble, emit Layer 1 facts, run Layer 2
  # extractors, merge. Enables imprecision tracing in the worker process
  # when requested — the flag lives in the worker's process dictionary,
  # which is naturally scoped to this Task.async_stream worker, and the
  # try/after guarantees the flag is cleared before the worker returns
  # to the async pool.
  defp extract_module(path, extractors, trace_imprecision, shape, memo) do
    if trace_imprecision, do: Helpers.enable_tracing()

    try do
      with {:ok, facts} <- module_facts(path, extractors, memo) do
        # Shaped here, in the worker, so the rows cross to the caller as
        # tuples of small integers or as the bytes of their lines rather
        # than as every string they hold.
        {:ok, shape.(facts)}
      end
    rescue
      exception -> {:ok, shape.(lost_module(path, describe(:error, exception, __STACKTRACE__)))}
    catch
      kind, reason -> {:ok, shape.(lost_module(path, describe(kind, reason, __STACKTRACE__)))}
    after
      if trace_imprecision, do: Helpers.disable_tracing()
    end
  end

  defp module_facts(path, extractors, memo) do
    with {:ok, data} <- Disassemble.disassemble_path(path) do
      mod_str = inspect(data.module)

      base_facts =
        Emit.emit_module(
          data.module,
          data.exports,
          data.imports,
          data.attributes,
          data.functions,
          data.line_table
        )

      # Decoded once — the relations the in-process passes read — for the
      # derived relations and for the control-flow graphs the extractors
      # walk; a module whose facts cannot be decoded keeps everything else
      # and loses only what those provide.
      {typed, errors} =
        attempt(
          "decode",
          fn -> base_facts |> Map.take(@typed_relations) |> Argus.Facts.decode() end,
          []
        )

      {cfgs, errors} = attempt("cfg", fn -> if typed, do: Cfg.build(typed), else: %{} end, errors)
      cfgs = cfgs || %{}
      {reaching, errors} = attempt("reaching", fn -> reaching(typed, data) end, errors)

      # Every call site indexed once; the extractors filter the index
      # rather than each walking the instruction stream.
      data =
        Map.merge(data, %{
          call_sites: Argus.Extractor.CallSites.index(data.module, data.functions),
          cfg: cfgs,
          typed: typed,
          reaching: reaching,
          origins_index: Argus.Extractor.Helpers.origins_index(%{reaching: reaching}),
          installed_specs: memo
        })
        |> with_debug_info(extractors)

      # One extractor's failure costs its own rows and nothing else.
      {extractor_facts, errors} =
        Enum.reduce(extractors, {%{}, errors}, fn extractor, {acc, errors} ->
          case attempt(inspect(extractor), fn -> extractor.extract(data) end, errors) do
            {nil, errors} -> {acc, errors}
            {facts, errors} -> {merge_facts(acc, facts), errors}
          end
        end)

      {conditional, errors} =
        attempt("conditional_call", fn -> derive_conditional_calls(base_facts, cfgs) end, errors)

      facts =
        base_facts
        |> merge_facts(extractor_facts)
        |> merge_facts(derive_def_use(reaching))
        |> merge_facts(conditional || %{})
        |> merge_facts(error_facts(mod_str, errors))

      {:ok, facts}
    end
  end

  # The extractors that read the debug-info chunk (`Helpers.debug_info/1`).
  # An Elixir module's chunk holds its whole definition, and inflating and
  # decoding it cost each of them as much as the rest of its work; it is
  # read once when any of them runs, and not at all when none does.
  @debug_info_readers [Argus.Extractors.Generated, Argus.Extractors.Specs]

  defp with_debug_info(data, extractors) do
    if Enum.any?(extractors, &(&1 in @debug_info_readers)) do
      Map.put(data, :debug_info, read_debug_info(data))
    else
      data
    end
  end

  # A chunk that cannot be read is no chunk, as it is to the extractors
  # reading it themselves: no extraction error is recorded for it.
  defp read_debug_info(data) do
    Helpers.debug_info(data)
  rescue
    _ -> :error
  end

  # What a run looks up once and every module asks again: the specs of
  # the remote modules the extractors read from the code path
  # (`Argus.Specs.installed/2`). Finding a module that is not loaded
  # walks the code path through the code server, which every worker
  # waits on in turn, and the answer cannot change while the run reads
  # the same path. The caller owns the table and deletes it when the run
  # is done; the workers read and fill it.
  defp new_memo, do: :ets.new(:argus_extraction_memo, [:set, :public, read_concurrency: true])

  # `{value, errors}`: the step's result, or nil with the failure added to
  # `errors` as `{step, reason}`.
  defp attempt(step, fun, errors) do
    {fun.(), errors}
  rescue
    exception -> {nil, [{step, describe(:error, exception, __STACKTRACE__)} | errors]}
  catch
    kind, reason -> {nil, [{step, describe(kind, reason, __STACKTRACE__)} | errors]}
  end

  defp error_facts(_mod_str, []), do: %{}

  defp error_facts(mod_str, errors) do
    %{extraction_error: for({step, reason} <- errors, do: [mod_str, step, reason])}
  end

  # The facts of a module none of whose facts survived: its one
  # `extraction_error` row.
  defp lost_module(path, reason) do
    error_facts(module_label(path), [{"pipeline", reason}])
  end

  defp maybe_intern(facts, nil), do: facts
  defp maybe_intern(facts, symbols), do: Argus.Facts.intern(facts, symbols)

  # The module's name as `function_def` spells it, read from the beam's
  # header alone; the path when even that fails (and a placeholder for
  # in-memory beam data, which has no path to show).
  defp module_label(path) do
    target = if BeamSpy.BeamFile.beam_data?(path), do: path, else: String.to_charlist(path)

    case :beam_lib.info(target) do
      info when is_list(info) -> inspect(Keyword.fetch!(info, :module))
      {:error, :beam_lib, _} -> unnamed(path)
    end
  rescue
    _ -> unnamed(path)
  end

  defp unnamed(path) do
    if BeamSpy.BeamFile.beam_data?(path), do: "(beam data)", else: path
  end

  # The failure on one line, with the innermost frame of the step that
  # raised it: enough to find the bug, deterministic for the same code and
  # input. The pipeline's own frames are where every step is called from,
  # so they name nothing.
  @reason_limit 500

  defp describe(kind, reason, stacktrace) do
    banner = kind |> Exception.format_banner(reason, stacktrace) |> one_line()

    at =
      Enum.find_value(stacktrace, fn
        {mod, _fun, _arity, _location} = entry when is_atom(mod) and mod != __MODULE__ ->
          if String.starts_with?(Atom.to_string(mod), "Elixir.Argus."),
            do: " (at #{Exception.format_stacktrace_entry(entry)})"

        _ ->
          nil
      end)

    String.slice(banner, 0, @reason_limit) <> (at || "")
  end

  defp one_line(text), do: text |> String.trim() |> String.replace(~r/\s*\R\s*/, " ")

  # Reaching definitions with the parameters as sources, once per module
  # and never over the merged program (no edge crosses a function, and a
  # per-module result is what an incremental consumer reuses for every
  # module an edit did not touch). They are read off the per-function
  # solutions `Argus.Instr.Reaching` keeps, which the emitter's value walks
  # may already have solved and the extractors' walks go on to query, so
  # each function is solved once; `Argus.Dataflow.reaching_uses/2` over
  # the facts is the same set, solved again. The extractors that follow
  # values read them from `module_data`, and def_use is the
  # instruction-to-instruction part — a parameter pseudo-definition is
  # killed like any other write, so it never changes which instructions'
  # writes reach a read.
  #
  # A module whose facts did not decode gets none, as it always has: the
  # extractors that read them read the facts too.
  defp reaching(nil, _data), do: nil
  defp reaching(_typed, data), do: Reaching.uses(data.module, data.functions)

  defp derive_def_use(nil), do: %{}

  # Sorted: `reaching` is a set of terms holding atoms, and a VM iterates
  # a small set in atom-table order, so the same module would otherwise
  # yield its rows in an order that depends on the VM that read it.
  defp derive_def_use(reaching) do
    rows =
      for {%InstrId{} = d, _reg, u} <- reaching,
          uniq: true,
          do: [InstrId.format(d), InstrId.format(u)]

    rows = Enum.sort(rows)

    if rows == [], do: %{}, else: %{def_use: rows}
  end

  # Call instructions whose block is control-dependent on a branch in the
  # same function — the calls that only happen on some paths. Positional
  # like def_use (keyed on instruction IDs), and derived here for the same
  # reason: the post-dominator tree exists in Argus.Cfg, and the
  # alternative is reconstructing it from `instruction`/`branch`/`jump`
  # rows in Datalog on every solve.
  defp derive_conditional_calls(base_facts, cfgs) do
    call_ids =
      for relation <- [:local_call, :remote_call, :bif_call],
          [id | _] <- Map.get(base_facts, relation, []),
          do: id

    conditional_blocks =
      Map.new(cfgs, fn {key, fun} ->
        {key, fun |> Cfg.Function.control_deps() |> Map.keys() |> MapSet.new()}
      end)

    rows =
      for id <- call_ids,
          {:ok, %InstrId{func: name, arity: arity, idx: idx}} <- [InstrId.parse(id)],
          fun = Map.get(cfgs, {name, arity}),
          fun != nil,
          block = Cfg.Function.block_at(fun, idx),
          block != nil,
          MapSet.member?(conditional_blocks[{name, arity}], block.id),
          do: [id]

    case rows do
      [] -> %{}
      rows -> %{conditional_call: Enum.sort(rows)}
    end
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
    with :ok <- touch_relations(output_dir) do
      Enum.reduce_while(facts, :ok, fn {relation, rows}, :ok ->
        path = Path.join(output_dir, "#{relation}.facts")

        # An explicitly-empty relation produces a zero-byte file, not a
        # lone newline: Souffle reads the blank line as a tuple with
        # missing columns and aborts with "Values missing in line 1".
        case File.write(path, Argus.Tsv.encode(Enum.reverse(rows))) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:write_failed, path, reason}}}
        end
      end)
    end
  end

  # Empty files for every schema relation, so Souffle never fails on a
  # missing .input file. Existing files are left alone.
  defp touch_relations(output_dir) do
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
  end

  @doc false
  # Kept for callers outside argus that wrote facts through it; `Argus.Tsv`
  # is the format.
  def rows_iodata(rows), do: Argus.Tsv.encode(rows)
end
