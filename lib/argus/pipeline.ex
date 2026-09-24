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

  ## Producers

  Each row has one producer: `:base`, the facts every extraction makes
  (`Emit`'s, `def_use` and `conditional_call`, and the extraction errors
  of the steps they come from), or the extractor that emitted it. A
  producer's rows depend on the modules and on its own code, and on no
  other producer's: that is what lets `run_shards/3` extract some
  producers on their own, into a directory each, and a store keep them
  apart (`Argus.Cache.Facts`) — or `extract_shards/3` return them apart
  in memory, for a caller that keeps them itself. `run/3` writes a
  relation's rows grouped by producer — `:base` first, then the
  extractors in the order `extractors:` names them, each group in module
  order — which is what joining the producers' directories in that order
  gives (`Argus.Pipeline.Shards`). Nearly every relation has one
  producer; the few with several are `extraction_error`, `imprecision`
  and `dynamic_call`.

  A module's failures stay with the module: an extractor that raises, or
  a module that outlives the per-module `:timeout`, is recorded as an
  `extraction_error` row (see `Argus.Schema`) and the run goes on over
  everything else. Only an input that cannot be read ends it with
  `{:error, reason}`.
  """

  alias Argus.Cfg
  alias Argus.Extractor.Facts
  alias Argus.Extractor.Helpers
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.{Base, Disassemble, Emit, Shards, Writer}

  @typedoc """
  Who emits a row: `:base` (the emitter and the derivations every
  extraction makes) or an extractor module.
  """
  @type producer :: :base | module()

  @typedoc """
  What `run_shards/3` reports beside the directories it wrote:

    * `lost` — the modules (as `extraction_error` names them) whose
      extraction timed out or whose worker exited. What they would have
      produced depends on the machine's load as much as on the code, so
      a run that lost one is no answer to keep.
    * `installed` — the modules whose specs were read from the code
      path (`Argus.Specs.installed/2`) while extracting: beyond the
      beams, what `Argus.Extractors.Specs`'s rows depend on.
    * `digests` — from `run_shards/3`, for each producer, the SHA-256
      (lowercase hex) of each file it wrote, by file name, hashed as the
      rows were written (`Argus.Pipeline.Writer.digests/1`): what a
      store keys the solves reading them on, without reading them back.
    * `bases` — with `keep_bases: true`, each module's base
      (`Argus.Pipeline.Base.keep/4`), in input order: nil for a module
      whose base was not computed (it could not be disassembled or
      emitted, or it was lost) or was read from `bases:`.
  """
  @type shard_info :: %{
          required(:lost) => [String.t()],
          required(:installed) => [module()],
          optional(:digests) => %{producer() => %{String.t() => String.t()}},
          optional(:bases) => [binary() | nil]
        }

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
          relations: :all | [atom()],
          bases: [binary() | nil],
          keep_bases: boolean()
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

  # The extractors that read the decoded facts (`Helpers.typed/1`): over
  # a kept base, which holds none, they are emitted and decoded again
  # only when one of them runs. `Argus.Cache.CodeClosureTest` fails when
  # an extractor off the list computes them.
  @typed_readers [
    Argus.Extractors.Dependence,
    Argus.Extractors.ParamFlow,
    Argus.Extractors.PidFlow
  ]

  @doc """
  The extractors that read `module_data.typed` (through
  `Argus.Extractor.Helpers.typed/1`). A kept base
  (`Argus.Pipeline.Base`) holds no decoded facts: over one, they are
  emitted and decoded again only when one of these runs, and any other
  extractor finds none in `module_data`.
  """
  @spec typed_readers() :: [module()]
  def typed_readers, do: @typed_readers

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

  Each producer's rows are written to a directory of its own inside
  `output_dir` and moved into place when the run is done (see
  "Producers" above); an extractor named twice in `extractors:` runs
  once.
  """
  @spec run(
          modules :: [Disassemble.module_input()],
          output_dir :: Path.t(),
          run_opts()
        ) ::
          {:ok, Path.t()} | {:error, term()}
  def run(modules, output_dir, opts \\ []) do
    producers = [:base | Enum.uniq(Keyword.get(opts, :extractors, []))]

    parts =
      Path.join(
        output_dir,
        ".argus-producers-#{:os.getpid()}-#{System.unique_integer([:positive])}"
      )

    dirs =
      producers |> Enum.with_index() |> Enum.map(fn {p, i} -> {p, Path.join(parts, "#{i}")} end)

    try do
      with :ok <- File.mkdir_p(output_dir),
           {:ok, _info} <- run_shards(modules, dirs, opts),
           :ok <-
             dirs
             |> Enum.map(&elem(&1, 1))
             |> Shards.parts()
             |> Shards.assemble(output_dir, :move),
           :ok <- touch_relations(output_dir) do
        {:ok, output_dir}
      end
    after
      File.rm_rf(parts)
    end
  end

  @doc """
  Extracts facts from the given modules and writes each producer's rows
  to a directory of its own: `dirs` pairs producers (`t:producer/0`)
  with directories, `:base` first when it is there. The extractors that
  run are the ones named; `:base` is computed whether or not it is
  named, since every extractor reads what it computes, and its rows are
  written only when it is. `extractors:` is ignored.

  A producer's directory holds a `.facts` file for each relation it
  emitted rows for, and nothing else: no empty files, unlike `run/3`.
  Its rows are the ones `run/3` writes for it — they do not depend on
  which other producers run — so joining the directories of `:base`
  and of each extractor, in `run/3`'s order, gives `run/3`'s directory
  (`Argus.Pipeline.Shards`). `relations:`, `trace_imprecision:`,
  `concurrency:` and `timeout:` mean what they do for `run/3`.

  Each module's base — what the extractors read of it besides its
  disassembly (`Argus.Pipeline.Base`) — can be kept and read back:
  `keep_bases: true` returns each one in `info.bases`, and `bases:`,
  one per module in input order (nil where there is none), has the
  extractors run over those in place of computing them. The extractors'
  rows are the same either way. A base read back is used only when
  `:base` is not among `dirs`: the base's own rows are the emitter's,
  which no kept base holds.

  Returns `{:ok, info}` (`t:shard_info/0`) or `{:error, reason}`.
  """
  @spec run_shards([Disassemble.module_input()], [{producer(), Path.t()}], run_opts()) ::
          {:ok, shard_info()} | {:error, term()}
  def run_shards(modules, dirs, opts \\ []) do
    written =
      case Keyword.get(opts, :relations, :all) do
        :all -> nil
        names -> MapSet.new(names)
      end

    selected = MapSet.new(dirs, &elem(&1, 0))
    extractors = for {producer, _dir} <- dirs, producer != :base, do: producer
    keep? = Keyword.get(opts, :keep_bases, false)
    how = %{base: MapSet.member?(selected, :base), keep: keep?}
    opts = Keyword.put(opts, :extractors, extractors)

    with :ok <- mkdir_all(dirs),
         {:ok, paths} <- Disassemble.resolve_paths(modules),
         {:ok, inputs} <- with_bases(paths, Keyword.get(opts, :bases), how) do
      writers = Map.new(dirs, fn {producer, dir} -> {producer, Writer.new(dir, written)} end)
      memo = new_memo()

      shape = fn produced, kept ->
        encoded =
          for {producer, facts} <- produced,
              MapSet.member?(selected, producer),
              do: {producer, Writer.encode(facts, written)}

        {encoded, kept}
      end

      try do
        inputs
        |> extract_stream(opts, memo, how, shape)
        |> Enum.reduce_while({:ok, writers, [], []}, fn
          {status, {encoded, kept}}, {:ok, writers, lost, bases}
          when status in [:ok, :lost] ->
            lost = if status == :lost, do: lost ++ lost_names(encoded), else: lost
            bases = if keep?, do: [kept | bases], else: bases

            case append_all(writers, encoded) do
              {:ok, writers} -> {:cont, {:ok, writers, lost, bases}}
              {:error, _} = error -> {:halt, error}
            end

          {:error, reason}, _ ->
            {:halt, {:error, reason}}
        end)
        |> case do
          {:ok, writers, lost, bases} ->
            close_all(writers)
            digests = Map.new(writers, fn {producer, w} -> {producer, Writer.digests(w)} end)
            info = %{lost: lost, installed: installed_reads(memo), digests: digests}
            {:ok, if(keep?, do: Map.put(info, :bases, Enum.reverse(bases)), else: info)}

          {:error, _} = error ->
            error
        end
      after
        close_all(writers)
        :ets.delete(memo)
      end
    end
  end

  # Each path with the base to read back for it, or nil: none when the
  # base's own rows are asked for.
  defp with_bases(paths, nil, _how), do: {:ok, Enum.map(paths, &{&1, nil})}
  defp with_bases(paths, _bases, %{base: true}), do: {:ok, Enum.map(paths, &{&1, nil})}

  defp with_bases(paths, bases, _how) when length(bases) == length(paths),
    do: {:ok, Enum.zip(paths, bases)}

  defp with_bases(paths, bases, _how),
    do: {:error, {:bases_mismatch, length(paths), length(bases)}}

  defp mkdir_all(dirs) do
    Enum.reduce_while(dirs, :ok, fn {_producer, dir}, :ok ->
      case File.mkdir_p(dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mkdir_failed, dir, reason}}}
      end
    end)
  end

  defp append_all(writers, encoded) do
    Enum.reduce_while(encoded, {:ok, writers}, fn {producer, bytes}, {:ok, writers} ->
      case Writer.append_encoded(Map.fetch!(writers, producer), bytes) do
        {:ok, writer} -> {:cont, {:ok, Map.put(writers, producer, writer)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp close_all(writers), do: Enum.each(writers, fn {_producer, w} -> Writer.close(w) end)

  # The module a lost module's one `extraction_error` row names, from
  # the encoded row: `<module>\t<step>\t<reason>`.
  defp lost_names(encoded) do
    for {:base, %{extraction_error: bytes}} <- encoded,
        [name | _] <- Argus.Tsv.decode(bytes),
        do: name
  end

  # The modules whose installed specs the run read: the memo's keys
  # (`Argus.Specs.installed/2` and the types it resolved through).
  defp installed_reads(memo) do
    for {{kind, module}, _value} <- :ets.tab2list(memo),
        kind in [:specs, :types],
        is_atom(module),
        uniq: true,
        do: module
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
      shape = extract_shape(format, Keyword.get(opts, :symbols))

      merged =
        try do
          paths
          |> Enum.map(&{&1, nil})
          |> extract_stream(opts, memo, %{base: true, keep: false}, shape)
          |> Enum.reduce(%{}, fn
            {status, module_facts}, acc when status in [:ok, :lost] ->
              merge_facts(acc, module_facts)

            {:error, reason}, _acc ->
              throw({:extraction_error, reason})
          end)
        after
          :ets.delete(memo)
        end

      {:ok, merged}
    end
  catch
    {:extraction_error, reason} -> {:error, reason}
  end

  @doc """
  Extracts facts from the given modules and returns each producer's rows
  apart, in memory: `run_shards/3`'s directories as `extract/2` returns
  facts.

  `producers` names the producers (`t:producer/0`) whose rows come back.
  The extractors that run are the ones named; `:base` is computed whether
  or not it is named, since every extractor reads what it computes. A
  producer's rows are the ones it gives beside any other producers (see
  "Producers"), each relation's in the order `run_shards/3` writes them,
  and a producer named that emitted no rows maps to an empty map. `format:`, `symbols:`,
  `trace_imprecision:`, `concurrency:` and `timeout:` mean what they do
  for `extract/2`; `extractors:` is ignored.

  Returns `{:ok, facts, info}`: each named producer's facts, and what
  `run_shards/3` reports beside them (`t:shard_info/0`). Only an input
  that cannot be read is an error.
  """
  @spec extract_shards([Disassemble.module_input()], [producer()], extract_opts()) ::
          {:ok, %{producer() => Emit.facts() | Argus.Facts.t()}, shard_info()}
          | {:error, term()}
  def extract_shards(modules, producers, opts \\ []) do
    format = Keyword.get(opts, :format, :raw)

    if format == :interned and not match?(%Argus.Symbols{}, opts[:symbols]) do
      raise ArgumentError, "format: :interned needs the symbols: table the ids refer to"
    end

    producers = Enum.uniq(producers)
    selected = MapSet.new(producers)
    extractors = for producer <- producers, producer != :base, do: producer
    opts = Keyword.put(opts, :extractors, extractors)
    finish = format_facts(format, Keyword.get(opts, :symbols))

    # The worker keeps the named producers' facts, in the order
    # `run_shards/3` writes them and formatted, and the names its base's
    # extraction errors give, which for a module it lost are the module's.
    shape = fn produced, _kept ->
      shards =
        for {p, facts} <- produced,
            MapSet.member?(selected, p),
            do: {p, facts |> in_file_order() |> finish.()}

      names = for {:base, %{extraction_error: rows}} <- produced, [name | _] <- rows, do: name
      {shards, names}
    end

    with {:ok, paths} <- Disassemble.resolve_paths(modules) do
      memo = new_memo()

      try do
        paths
        |> Enum.map(&{&1, nil})
        |> extract_stream(
          opts,
          memo,
          %{base: MapSet.member?(selected, :base), keep: false},
          shape
        )
        |> Enum.reduce_while({:ok, [], []}, fn
          {status, {shards, names}}, {:ok, chunks, lost} when status in [:ok, :lost] ->
            lost = if status == :lost, do: lost ++ names, else: lost
            {:cont, {:ok, [shards | chunks], lost}}

          {:error, reason}, _ ->
            {:halt, {:error, reason}}
        end)
        |> case do
          {:ok, chunks, lost} ->
            facts = join_shards(producers, Enum.reverse(chunks))
            {:ok, facts, %{lost: lost, installed: installed_reads(memo)}}

          {:error, _} = error ->
            error
        end
      after
        :ets.delete(memo)
      end
    end
  end

  # A module's facts as `Writer` writes them: the relations with rows,
  # each in the order it lands in the file (extraction prepends).
  defp in_file_order(facts) do
    for {relation, rows} <- facts, rows != [], into: %{}, do: {relation, Enum.reverse(rows)}
  end

  # Each producer's facts over the modules, `modules` holding each
  # module's `[{producer, facts}]` in module order: a relation's rows are
  # its rows from each module, in that order.
  defp join_shards(producers, modules) do
    by_producer =
      modules
      |> Enum.concat()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(producers, fn producer ->
      facts =
        by_producer
        |> Map.get(producer, [])
        |> Enum.flat_map(&Map.to_list/1)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {relation, rows} -> {relation, Enum.concat(rows)} end)

      {producer, facts}
    end)
  end

  # One `{:ok, shaped} | {:lost, shaped} | {:error, reason}` per module,
  # in input order: `:lost` for a module that outlived the timeout or
  # whose worker exited, whose facts are its one `extraction_error` row.
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
  # `shape` is what the worker does to a module's facts — a list of
  # `{producer, facts}`, `:base` first — before they cross to the
  # caller, which takes them one module at a time in input order:
  # merging and interning them (`extract/2`), or encoding each
  # producer's as the lines of its files (`run_shards/3`), so the caller
  # only writes. Encoding in the caller left the workers waiting on it: on
  # the Phoenix stack writing the facts took longer than extracting them
  # at eight workers.
  defp extract_stream(inputs, opts, memo, how, shape) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    extractors = Keyword.get(opts, :extractors, [])
    task_timeout = Keyword.get(opts, :timeout, @default_timeout)
    trace_imprecision = Keyword.get(opts, :trace_imprecision, false)

    inputs
    |> Task.async_stream(
      fn {path, kept} ->
        how = Map.put(how, :kept, kept)
        extract_module(path, extractors, trace_imprecision, how, shape, memo)
      end,
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

      {:exit, {{path, _kept}, :timeout}} ->
        reason = "extraction did not finish within #{task_timeout} ms"
        {:lost, shape.(lost_module(path, reason), nil)}

      {:exit, {{path, _kept}, reason}} ->
        reason = "extraction exited: #{one_line(inspect(reason))}"
        {:lost, shape.(lost_module(path, reason), nil)}
    end)
  end

  # Per-module extraction: disassemble, emit Layer 1 facts, run Layer 2
  # extractors, merge. Enables imprecision tracing in the worker process
  # when requested — the flag lives in the worker's process dictionary,
  # which is naturally scoped to this Task.async_stream worker, and the
  # try/after guarantees the flag is cleared before the worker returns
  # to the async pool.
  defp extract_module(path, extractors, trace_imprecision, how, shape, memo) do
    if trace_imprecision, do: Facts.enable_tracing()

    try do
      with {:ok, facts, kept} <- module_facts(path, extractors, memo, how) do
        # Shaped here, in the worker, so the rows cross to the caller as
        # tuples of small integers or as the bytes of their lines rather
        # than as every string they hold.
        {:ok, shape.(facts, kept)}
      end
    rescue
      exception ->
        {:ok, shape.(lost_module(path, describe(:error, exception, __STACKTRACE__)), nil)}
    catch
      kind, reason ->
        {:ok, shape.(lost_module(path, describe(kind, reason, __STACKTRACE__)), nil)}
    after
      if trace_imprecision, do: Facts.disable_tracing()
    end
  end

  # `{:ok, [{producer, facts}], kept}`, `:base` first and then each
  # extractor in order: what each producer made of the module, its
  # failures with it (a base step's in `:base`, an extractor's in its
  # own), and — when `how.keep` asks — its base (`Argus.Pipeline.Base`).
  # `how.base` says whether the base's own rows are wanted: the
  # derivations only they hold are skipped when not, and a base kept
  # from an earlier run (`how.kept`) stands in for computing one.
  defp module_facts(path, extractors, memo, %{kept: kept} = how) when is_binary(kept) do
    case restore(kept, path) do
      {:ok, restored} ->
        data =
          restored.data
          |> Map.merge(%{cfg: restored.cfg, reaching: restored.reaching})
          |> with_typed(restored.typed?, extractors)
          |> extractor_data(memo, extractors)

        {:ok, [{:base, %{}} | run_extractors(data, extractors)], nil}

      :error ->
        module_facts(path, extractors, memo, %{how | kept: nil})
    end
  end

  defp module_facts(path, extractors, memo, how) do
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
      {typed, errors} = attempt("decode", fn -> decode_typed(base_facts) end, [])

      {cfgs, errors} = attempt("cfg", fn -> if typed, do: Cfg.build(typed), else: %{} end, errors)
      cfgs = cfgs || %{}
      {reaching, errors} = attempt("reaching", fn -> reaching(typed, data) end, errors)
      kept = if how.keep, do: keep(data, typed, cfgs, reaching)

      produced =
        data
        |> Map.merge(%{cfg: cfgs, typed: typed, reaching: reaching})
        |> extractor_data(memo, extractors)
        |> run_extractors(extractors)

      base =
        if how.base do
          {conditional, errors} =
            attempt(
              "conditional_call",
              fn -> derive_conditional_calls(base_facts, cfgs) end,
              errors
            )

          base_facts
          |> merge_facts(derive_def_use(reaching))
          |> merge_facts(conditional || %{})
          |> merge_facts(error_facts(mod_str, errors))
        else
          %{}
        end

      {:ok, [{:base, base} | produced], kept}
    end
  end

  # What every extractor reads besides the disassembly and the parts the
  # base computed: every call site indexed once (the extractors filter
  # the index rather than each walking the instruction stream), the
  # origins of each read, the run's memo of installed specs, and the
  # debug-info chunk when an extractor reads it.
  defp extractor_data(data, memo, extractors) do
    data
    |> Map.merge(%{
      call_sites: Argus.Extractor.CallSites.index(data.module, data.functions),
      origins_index: Argus.Extractor.Identity.origins_index(%{reaching: data.reaching}),
      installed_specs: memo
    })
    |> with_debug_info(extractors)
  end

  # One extractor's failure costs its own rows and nothing else.
  defp run_extractors(data, extractors) do
    mod_str = inspect(data.module)

    for extractor <- extractors do
      case attempt(inspect(extractor), fn -> extractor.extract(data) end, []) do
        {nil, failed} -> {extractor, error_facts(mod_str, failed)}
        {facts, []} -> {extractor, facts}
      end
    end
  end

  # The base kept for a later run; a base that cannot be kept is not,
  # and the facts are what they would have been.
  defp keep(data, typed, cfgs, reaching) do
    Base.keep(data, typed, cfgs, reaching)
  rescue
    _ -> nil
  end

  # A kept base read back; one that cannot be read is computed afresh.
  defp restore(kept, path) do
    {:ok, Base.restore(kept, path)}
  rescue
    _ -> :error
  end

  defp decode_typed(base_facts),
    do: base_facts |> Map.take(@typed_relations) |> Argus.Facts.decode()

  # A kept base holds no decoded facts (`Argus.Pipeline.Base`): none when
  # they could not be decoded, as when the base was computed; emitted
  # and decoded again when an extractor that reads them runs; for any
  # other, no `typed` in the module data, and
  # `Argus.Extractor.Helpers.typed/1` computes them should one ask after
  # all.
  defp with_typed(data, false, _extractors), do: Map.put(data, :typed, nil)

  defp with_typed(data, true, extractors) do
    if Enum.any?(extractors, &(&1 in @typed_readers)) do
      base_facts =
        Emit.emit_module(
          data.module,
          data.exports,
          data.imports,
          data.attributes,
          data.functions,
          data.line_table
        )

      {typed, _errors} = attempt("decode", fn -> decode_typed(base_facts) end, [])
      Map.put(data, :typed, typed)
    else
      data
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
  # `extraction_error` row, which is the base's.
  defp lost_module(path, reason) do
    [{:base, error_facts(module_label(path), [{"pipeline", reason}])}]
  end

  # What `extract/2`'s workers make of a module's facts: the producers'
  # merged, `:base` first. Decoding each module's rows where they were
  # extracted gives the rows decoding the merged facts would (a row
  # decodes on its own), in parallel: decoding the Phoenix stack's in
  # the caller took longer than extracting it.
  defp extract_shape(format, symbols) do
    finish = format_facts(format, symbols)

    fn produced, _kept ->
      produced
      |> Enum.reduce(%{}, fn {_producer, facts}, acc -> merge_facts(acc, facts) end)
      |> finish.()
    end
  end

  # Raw rows as `format:` asks for them.
  defp format_facts(:raw, _symbols), do: & &1
  defp format_facts(:typed, _symbols), do: &Argus.Facts.decode/1
  defp format_facts(:interned, symbols), do: &Argus.Facts.intern(&1, symbols)

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
    |> case do
      :ok -> touch_relations(output_dir)
      error -> error
    end
  end

  # Empty files for every schema relation, so Souffle never fails on a
  # missing .input file. Existing files are left alone: the directory is
  # listed once, where asking after each file was most of a small
  # extraction's time.
  defp touch_relations(output_dir) do
    case File.ls(output_dir) do
      {:ok, names} -> touch_missing(output_dir, MapSet.new(names))
      {:error, reason} -> {:error, {:write_failed, output_dir, reason}}
    end
  end

  defp touch_missing(output_dir, existing) do
    Enum.reduce_while(Argus.Schema.names(), :ok, fn name, :ok ->
      file = "#{name}.facts"

      if MapSet.member?(existing, file) do
        {:cont, :ok}
      else
        path = Path.join(output_dir, file)

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
