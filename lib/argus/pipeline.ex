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
    merged facts in memory, and `extract_module/2` one module's, each
    producer's apart, as the query graph keeps them
    (`Argus.Graph.Extraction`).

  ## Producers

  Each row has one producer: `:base`, the facts every extraction makes
  (`Emit`'s, `def_use` and `conditional_call`, and the extraction errors
  of the steps they come from), or the extractor that emitted it. A
  producer's rows depend on the module and on its own code, and on no
  other producer's: that is what lets the query graph extract some
  producers of a module on their own (`extract_module/2`), over the
  module's kept base (`Argus.Pipeline.Base`), and keep each producer's
  rows apart. `run/3` writes a relation's rows module by module, in
  input order, and within a module producer by producer — `:base`
  first, then the extractors in the order `extractors:` names them.
  Nearly every relation has one producer; the few with several are
  `extraction_error`, `imprecision` and `dynamic_call`.

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
  alias Argus.Pipeline.{Base, Disassemble, Emit, Writer}
  alias Argus.Schema.Reads
  alias Argus.Specs.Memo

  @typedoc """
  Who emits a row: `:base` (the emitter and the derivations every
  extraction makes) or an extractor module.
  """
  @type producer :: :base | module()

  @type extract_opts :: [
          concurrency: pos_integer(),
          extractors: [module()],
          timeout: timeout(),
          trace_imprecision: boolean(),
          format: :raw | :typed,
          specs_source: Argus.Specs.Source.t()
        ]

  @type run_opts :: [
          specs_source: Argus.Specs.Source.t(),
          concurrency: pos_integer(),
          extractors: [module()],
          timeout: timeout(),
          trace_imprecision: boolean(),
          relations: :all | [atom()] | {:except, [atom()]}
        ]

  @default_timeout 120_000

  # The Layer-1 relations the in-process passes read from a module's
  # decoded facts: `Argus.Cfg`, `Argus.Dataflow` and the extractors that
  # take `module_data.typed` (Dependence, ParamFlow, TermFlow). Decoding
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

  # The extractors that read the decoded facts (`Helpers.typed/1`): a
  # kept base's are read back only when one of them runs.
  # `Argus.Graph.Identity.ProducerClosureTest` fails when an extractor off
  # the list computes them.
  @typed_readers [
    Argus.Extractors.Dependence,
    Argus.Extractors.ParamFlow,
    Argus.Extractors.SecurityValues,
    Argus.Extractors.SharedStore,
    Argus.Extractors.ResultChecks,
    Argus.Extractors.EtfAllocation,
    Argus.Extractors.TermValidation,
    Argus.Extractors.CodeInjection,
    Argus.Extractors.SqlInjection,
    Argus.Extractors.HtmlInjection,
    Argus.Extractors.PathTraversal,
    Argus.Extractors.TermFlow
  ]

  @doc """
  The extractors that read `module_data.typed` (through
  `Argus.Extractor.Helpers.typed/1`): over a kept base
  (`Argus.Pipeline.Base`), the decoded facts are read back only when
  one of them runs, and any other extractor finds none in
  `module_data`.
  """
  @spec typed_readers() :: [module()]
  def typed_readers, do: @typed_readers

  @doc """
  Extracts facts from the given modules and writes `.facts` files to `output_dir`.

  Modules can be atoms (resolved via `:code.which/1`), string paths to
  `.beam` files, or raw beam data binaries. Returns `{:ok, output_dir}`
  or `{:error, reason}`.

  Every schema relation gets a file (Souffle fails on a missing `.input`
  file), but `relations:` limits which ones receive rows — the ones
  named, or with `{:except, names}` every one but those: the rest stay
  empty. The query graph uses it to keep apart the relations that exist
  only for the in-process control-flow and dataflow passes
  (`Argus.Schema.in_process_only/0`), which no program of argus's reads
  and which are most of the fact volume.

  Each module's rows are written as its extraction completes, module by
  module in input order (see "Producers" above); an extractor named
  twice in `extractors:` runs once.
  """
  @spec run(
          modules :: [Disassemble.module_input()],
          output_dir :: Path.t(),
          run_opts()
        ) ::
          {:ok, Path.t()} | {:error, term()}
  def run(modules, output_dir, opts \\ []) do
    extractors = Enum.uniq(Keyword.get(opts, :extractors, []))
    written = Writer.written(Keyword.get(opts, :relations, :all))
    order = [:base | extractors]
    opts = Keyword.put(opts, :extractors, extractors)

    # Each producer's rows encoded in the worker, in producer order, so
    # the caller only writes.
    shape = fn produced, _kept, _reads ->
      by_producer = Map.new(produced)

      for producer <- order,
          facts = Map.get(by_producer, producer),
          facts != nil,
          do: Writer.encode(facts, written)
    end

    with :ok <- mkdir(output_dir),
         {:ok, paths} <- Disassemble.resolve_paths(modules) do
      memo = new_memo(opts)

      try do
        paths
        |> Enum.map(&{&1, nil})
        |> extract_stream(opts, memo, %{base: true, keep: false}, shape)
        |> Enum.reduce_while({:ok, Writer.new(output_dir, written)}, fn
          {status, encoded}, {:ok, writer} when status in [:ok, :lost] ->
            case append_all(writer, encoded) do
              {:ok, writer} -> {:cont, {:ok, writer}}
              {:error, reason} -> {:halt, {:error, reason, writer}}
            end

          {:error, reason}, {:ok, writer} ->
            {:halt, {:error, reason, writer}}
        end)
        |> case do
          {:ok, writer} ->
            Writer.close(writer)
            with :ok <- touch_relations(output_dir), do: {:ok, output_dir}

          {:error, reason, writer} ->
            Writer.close(writer)
            {:error, reason}
        end
      after
        Memo.close(memo)
      end
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, dir, reason}}
    end
  end

  defp append_all(writer, encoded) do
    Enum.reduce_while(encoded, {:ok, writer}, fn bytes, {:ok, writer} ->
      case Writer.append_encoded(writer, bytes) do
        {:ok, writer} -> {:cont, {:ok, writer}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # The modules whose installed specs the run read: the memo's keys
  # (`Argus.Specs.installed/2` and the types it resolved through).
  defp installed_reads(memo) do
    memo
    |> Memo.table()
    |> :ets.select([
      {{{:"$1", :"$2"}, :_},
       [{:orelse, {:"=:=", :"$1", :specs}, {:"=:=", :"$1", :types}}, {:is_atom, :"$2"}], [:"$2"]}
    ])
    |> Enum.uniq()
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
    format = Keyword.get(opts, :format, :raw)

    with {:ok, paths} <- Disassemble.resolve_paths(modules) do
      memo = new_memo(opts)
      shape = extract_shape(format)

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
          Memo.close(memo)
        end

      {:ok, merged}
    end
  catch
    {:extraction_error, reason} -> {:error, reason}
  end

  @typedoc """
  What `extract_module/2` made of one module:

    * `status` — `:ok`, or `:lost` when the module outlived the
      per-module timeout or its worker exited: its facts are then its
      one `extraction_error` row, the base's, and they depend on the
      machine's load as much as on the code;
    * `facts` — each producer's rows as `Argus.Pipeline.Writer.encode/2`
      encodes them (per relation, the bytes of its lines), for the
      producers asked for, `:base` too when the module was lost;
    * `reads` — what each producer's rows depend on of the schema
      (`Argus.Schema.Reads`), sorted, for the producers asked for: the
      base's what computing the module's base read (and its own
      derivations, when its rows were asked for), an extractor's those
      and its own;
    * `installed` — the modules whose specs were read from the code path;
    * `base` — the module's base, kept (`Argus.Pipeline.Base`), when
      `keep_base: true` asked and it was computed; else nil.
  """
  @type module_extraction :: %{
          status: :ok | :lost,
          facts: %{producer() => %{atom() => binary()}},
          reads: %{producer() => [Argus.Schema.Reads.read()]},
          installed: [module()],
          base: binary() | nil
        }

  @doc """
  Extracts one module, for the producers named, each producer's rows
  apart: what the query graph keeps per module and producer
  (`Argus.Graph.Pack`).

  `producers` names the producers whose rows come back; `:base` is
  computed whether or not it is named, since every extractor reads what
  it computes — unless `base:` hands in one kept from an earlier run,
  which the extractors then run over (only when `:base` is not named:
  the base's own rows are the emitter's, which no kept base holds).
  `keep_base: true` returns the base computed, for a later run.
  `relations:`, `trace_imprecision:` and `timeout:` mean what they do
  for `run/3`.

  Returns `{:ok, extraction}` (`t:module_extraction/0`), or
  `{:error, reason}` when the input cannot be read at all.
  """
  @spec extract_module(Disassemble.module_input(), keyword()) ::
          {:ok, module_extraction()} | {:error, term()}
  def extract_module(input, opts) do
    producers = opts |> Keyword.fetch!(:producers) |> Enum.uniq()
    selected = MapSet.new(producers)
    extractors = for producer <- producers, producer != :base, do: producer
    written = Writer.written(Keyword.get(opts, :relations, :all))
    how = %{base: MapSet.member?(selected, :base), keep: Keyword.get(opts, :keep_base, false)}
    kept = if how.base, do: nil, else: Keyword.get(opts, :base)
    opts = opts |> Keyword.put(:extractors, extractors) |> Keyword.put(:concurrency, 1)

    # Every producer's rows, encoded in the worker; a lost module's are
    # the base's error row, whether or not the base was asked for.
    shape = fn produced, kept_base, reads ->
      encoded = Map.new(produced, fn {p, facts} -> {p, Writer.encode(facts, written)} end)
      {encoded, kept_base, reads}
    end

    with {:ok, [path]} <- Disassemble.resolve_paths([input]) do
      memo = new_memo(opts)

      try do
        [{path, kept}]
        |> extract_stream(opts, memo, how, shape)
        |> Enum.to_list()
        |> case do
          [{status, {encoded, kept_base, reads}}] when status in [:ok, :lost] ->
            asked = if status == :lost, do: [:base | producers], else: producers

            {:ok,
             %{
               status: status,
               facts: Map.new(Enum.uniq(asked), &{&1, Map.get(encoded, &1, %{})}),
               reads: Map.new(producers, &{&1, Map.get(reads, &1, [])}),
               installed: installed_reads(memo),
               base: kept_base
             }}

          [{:error, reason}] ->
            {:error, reason}
        end
      after
        Memo.close(memo)
      end
    end
  end

  @doc """
  Extracts an already disassembled module or function partition.

  Uses the same passes and error handling as `extract_module/2`, in the calling
  process. The caller owns scheduling and timeouts. `base:` can supply a kept
  base when only extractor rows are requested; `keep_base:` returns one for reuse.

  With `keep_base: true`, `on_prepared:` receives the kept binary and its live
  prepared data before any extractors run. This lets a worker reuse that data
  without immediately decoding the binary. The callback never receives the
  installed-spec memo, and its result does not enter the extraction value.
  """
  @spec extract_data(Disassemble.module_data(), keyword()) ::
          {:ok, module_extraction()} | {:error, term()}
  def extract_data(data, opts) do
    producers = opts |> Keyword.fetch!(:producers) |> Enum.uniq()
    extractors = Enum.reject(producers, &(&1 == :base))
    base? = :base in producers

    how = %{
      base: base?,
      keep: Keyword.get(opts, :keep_base, false),
      kept: if(base?, do: nil, else: Keyword.get(opts, :base)),
      on_prepared: Keyword.get(opts, :on_prepared)
    }

    memo = new_memo(opts)
    was_tracing = Facts.tracing_enabled?()
    if Keyword.get(opts, :trace_imprecision, false), do: Facts.enable_tracing()

    try do
      written = Writer.written(Keyword.get(opts, :relations, :all))

      shape = fn produced, kept, reads ->
        {Map.new(produced, fn {producer, rows} -> {producer, Writer.encode(rows, written)} end),
         kept, reads}
      end

      with {:ok, {encoded, kept, reads}} <-
             extract_module(data, extractors, false, how, shape, memo) do
        {:ok,
         %{
           status: :ok,
           facts: Map.new(producers, &{&1, Map.get(encoded, &1, %{})}),
           reads: Map.take(reads, producers),
           installed: installed_reads(memo),
           base: kept
         }}
      end
    after
      Memo.close(memo)
      if not was_tracing, do: Facts.disable_tracing()
    end
  end

  @doc """
  Runs extractors over prepared disassembly, CFGs, and reaching definitions.

  The caller restores any serialized reaching solutions before calling this.
  Installed-spec memoization is scoped to the call and never enters its result.
  """
  @spec extract_prepared(map(), keyword()) :: {:ok, module_extraction()}
  def extract_prepared(data, opts) do
    extractors = opts |> Keyword.fetch!(:producers) |> Enum.uniq()
    memo = new_memo(opts)
    was_tracing = Facts.tracing_enabled?()
    if Keyword.get(opts, :trace_imprecision, false), do: Facts.enable_tracing()

    try do
      produced = data |> extractor_data(memo, extractors) |> run_extractors(extractors)
      written = Writer.written(Keyword.get(opts, :relations, :all))

      {:ok,
       %{
         status: :ok,
         facts: Map.new(produced, fn {p, rows, _reads} -> {p, Writer.encode(rows, written)} end),
         reads: Map.new(produced, fn {p, _rows, reads} -> {p, reads} end),
         installed: installed_reads(memo),
         base: nil
       }}
    after
      Memo.close(memo)
      if not was_tracing, do: Facts.disable_tracing()
    end
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
  # merging them (`extract/2`), or encoding each producer's as the lines
  # of its files (`run/3`, `extract_module/2`), so the caller only
  # writes. Encoding in the caller left the workers waiting on it: on
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
        {:lost, shape.(lost_module(path, reason), nil, %{})}

      {:exit, {{path, _kept}, reason}} ->
        reason = "extraction exited: #{one_line(inspect(reason))}"
        {:lost, shape.(lost_module(path, reason), nil, %{})}
    end)
  end

  # Per-module extraction: disassemble, emit Layer 1 facts, run Layer 2
  # extractors, merge. Enables imprecision tracing in the worker process
  # when requested — the flag lives in the worker's process dictionary,
  # which is naturally scoped to this Task.async_stream worker, and the
  # try/after guarantees the flag is cleared before the worker returns
  # to the async pool.
  #
  # `shape` takes the module's facts, its kept base and the schema
  # reads (`Argus.Schema.Reads`) each producer's rows depend on. A module
  # whose extraction raised past every step's own rescue is the base's
  # one `extraction_error` row, and depends on whatever was read before
  # the raise.
  defp extract_module(path, extractors, trace_imprecision, how, shape, memo) do
    if trace_imprecision, do: Facts.enable_tracing()

    try do
      case Reads.track(fn -> shaped_module(path, extractors, how, shape, memo) end) do
        {{:crashed, facts}, recorded} -> {:ok, shape.(facts, nil, %{base: recorded})}
        {result, _recorded} -> result
      end
    after
      if trace_imprecision, do: Facts.disable_tracing()
    end
  end

  defp shaped_module(path, extractors, how, shape, memo) do
    with {:ok, facts, kept, reads} <- module_facts(path, extractors, memo, how) do
      # Shaped here, in the worker, so the rows cross to the caller as
      # tuples of small integers or as the bytes of their lines rather
      # than as every string they hold.
      {:ok, shape.(facts, kept, reads)}
    end
  rescue
    exception -> {:crashed, lost_module(path, describe(:error, exception, __STACKTRACE__))}
  catch
    kind, reason -> {:crashed, lost_module(path, describe(kind, reason, __STACKTRACE__))}
  end

  # `{:ok, [{producer, facts}], kept, reads}`, `:base` first and then
  # each extractor in order: what each producer made of the module, its
  # failures with it (a base step's in `:base`, an extractor's in its
  # own), when `how.keep` asks its base (`Argus.Pipeline.Base`), and
  # what each producer read of the schema: the base what computing the
  # module's base read and its own derivations, an extractor that and
  # its own reads. `how.base` says whether the base's own rows are
  # wanted: the derivations only they hold are skipped when not, and a
  # base kept from an earlier run (`how.kept`) stands in for computing
  # one.
  defp module_facts(path, extractors, memo, how) do
    case Reads.track(fn -> module_base(path, extractors, memo, how) end) do
      {{:ok, data, derive, kept}, module_reads} ->
        produced = run_extractors(data, extractors)
        {base, base_reads} = Reads.track(fn -> if how.base, do: derive.(), else: %{} end)

        reads =
          Map.new([
            {:base, :ordsets.union(module_reads, base_reads)}
            | for(
                {extractor, _facts, own} <- produced,
                do: {extractor, :ordsets.union(module_reads, own)}
              )
          ])

        facts = [
          {:base, base} | for({extractor, facts, _own} <- produced, do: {extractor, facts})
        ]

        {:ok, facts, kept, reads}

      {{:error, _} = error, _module_reads} ->
        error
    end
  end

  # What the extractors read of a module: `{:ok, data, derive, kept}`,
  # the module data they run over, the derivation of the base's own
  # rows (a function, run only when they are wanted), and the base to
  # keep, if asked for. A kept base that cannot be read is computed
  # afresh.
  defp module_base(path, extractors, memo, %{kept: kept} = how) when is_binary(kept) do
    case restore(kept, beam_input(path), extractors) do
      {:ok, restored} ->
        data =
          restored.data
          |> Map.merge(%{cfg: restored.cfg, reaching: restored.reaching})
          |> with_typed(restored.typed)
          |> extractor_data(memo, extractors)

        {:ok, data, fn -> %{} end, nil}

      :error ->
        module_base(path, extractors, memo, %{how | kept: nil})
    end
  end

  defp module_base(path, extractors, memo, how) do
    with {:ok, data} <- disassemble(path) do
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

      data =
        data
        |> Map.merge(%{cfg: cfgs, typed: typed, reaching: reaching})
        |> prepare_indexes()

      case {kept, Map.get(how, :on_prepared)} do
        {kept, callback} when is_binary(kept) and is_function(callback, 2) ->
          callback.(kept, data)

        _ ->
          :ok
      end

      data = extractor_data(data, memo, extractors)

      derive = fn ->
        {conditional, errors} =
          attempt(
            "conditional_call",
            fn -> derive_conditional_calls(base_facts, cfgs) end,
            errors
          )

        {order, errors} =
          attempt("block_order", fn -> derive_block_order(base_facts, cfgs) end, errors)

        base_facts
        |> merge_facts(derive_def_use(reaching))
        |> merge_facts(conditional || %{})
        |> merge_facts(order || %{})
        |> merge_facts(error_facts(mod_str, errors))
      end

      {:ok, data, derive, kept}
    end
  end

  defp disassemble(%{module: _, functions: _} = data), do: {:ok, data}
  defp disassemble(path), do: Disassemble.disassemble_path(path)

  defp beam_input(%{} = data), do: Map.get(data, :beam, "")
  defp beam_input(path), do: path

  # What every extractor reads besides the disassembly and the parts the
  # base computed: every call site indexed once (the extractors filter
  # the index rather than each walking the instruction stream), the
  # origins of each read, the run's memo of installed specs, and the
  # debug-info chunk when an extractor reads it.
  @doc "Shares immutable call-site and register-origin indexes between extractor calls."
  @spec prepare_indexes(map()) :: map()
  def prepare_indexes(data) do
    data
    |> Map.put_new_lazy(:call_sites, fn ->
      Argus.Extractor.CallSites.index(data.module, data.functions)
    end)
    |> Map.put_new_lazy(:origins_index, fn ->
      Argus.Extractor.Identity.origins_index(%{reaching: data.reaching})
    end)
  end

  defp extractor_data(data, memo, extractors) do
    data
    |> prepare_indexes()
    |> Map.put(:installed_specs, memo)
    |> with_debug_info(extractors)
  end

  # One extractor's failure costs its own rows and nothing else. Each
  # comes back with what it read of the schema itself.
  defp run_extractors(data, extractors) do
    mod_str = inspect(data.module)

    for extractor <- extractors do
      {result, reads} =
        Reads.track(fn ->
          attempt(inspect(extractor), fn -> well_formed!(extractor.extract(data)) end, [])
        end)

      case result do
        {nil, failed} -> {extractor, error_facts(mod_str, failed), reads}
        {facts, []} -> {extractor, facts, reads}
      end
    end
  end

  # Every column is a string, as `Argus.Tsv` writes it. A value of any
  # other type is the extractor's bug, and it fails the extractor's own
  # step here: met later, by the writer, it failed the whole module, and
  # that failure was recorded as the base's, kept under a key that holds
  # none of the extractor's code, so the kept rows went on serving the
  # lost module after the extractor was fixed.
  defp well_formed!(facts) do
    Enum.each(facts, fn {relation, rows} ->
      case Enum.find(rows, &(not Enum.all?(&1, fn value -> is_binary(value) end))) do
        nil -> :ok
        row -> raise ArgumentError, "a #{relation} row holds a non-string: #{inspect(row)}"
      end
    end)

    facts
  end

  # The base kept for a later run; a base that cannot be kept is not,
  # and the facts are what they would have been.
  defp keep(data, typed, cfgs, reaching) do
    Base.keep(data, typed, cfgs, reaching)
  rescue
    _ -> nil
  end

  # A kept base read back, its decoded facts only for an extractor that
  # reads them; one that cannot be read is computed afresh.
  defp restore(kept, path, extractors) do
    {:ok, Base.restore(kept, path, typed: Enum.any?(extractors, &(&1 in @typed_readers)))}
  rescue
    _ -> :error
  end

  defp decode_typed(base_facts),
    do: base_facts |> Map.take(@typed_relations) |> Argus.Facts.decode()

  # Decoded facts not read back leave no `typed` in the module data:
  # `Argus.Extractor.Helpers.typed/1` computes them for an extractor that
  # asks after all.
  defp with_typed(data, {:ok, typed}), do: Map.put(data, :typed, typed)
  defp with_typed(data, :not_read), do: data

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
  #
  # The immutable source stays on the worker's heap, outside ETS. Only spec
  # results and read markers enter the table, so collecting reads never copies
  # the project's full source index.
  defp new_memo(opts) do
    Memo.new(Keyword.get(opts, :specs_source))
  end

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
  defp extract_shape(format) do
    finish = format_facts(format)

    fn produced, _kept, _reads ->
      produced
      |> Enum.reduce(%{}, fn {_producer, facts}, acc -> merge_facts(acc, facts) end)
      |> finish.()
    end
  end

  # Raw rows as `format:` asks for them.
  defp format_facts(:raw), do: & &1
  defp format_facts(:typed), do: &Argus.Facts.decode/1

  # The module's name as `function_def` spells it, read from the beam's
  # header alone; the path when even that fails (and a placeholder for
  # in-memory beam data, which has no path to show).
  defp module_label(%{module: module}), do: inspect(module)

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

  # Call instructions that do not run on every path through their
  # function that completes — the calls that only happen on some paths.
  # A path that raises is none of them: a clause head failing into
  # func_info (Erlang's `init([]) ->`) or a badmatch decides nothing a
  # caller goes on from (Cfg.Function.completing_blocks/1). A function
  # no path of which completes falls back to control dependence.
  # Positional like def_use (keyed on instruction IDs), and derived here
  # for the same reason: the graphs exist in Argus.Cfg, and the
  # alternative is reconstructing them in Datalog on every solve.
  defp derive_conditional_calls(base_facts, cfgs) do
    call_ids =
      for relation <- [:local_call, :remote_call, :bif_call],
          [id | _] <- Map.get(base_facts, relation, []),
          do: id

    raising = raising_tail_blocks(base_facts, cfgs)

    conditional_blocks =
      Map.new(cfgs, fn {key, fun} ->
        {key, conditional_blocks(fun, Map.get(raising, key, MapSet.new()))}
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

  # The basic block of the instructions a rule asks the order of
  # (site_block), and the flow between the blocks holding one
  # (block_flow): what clientlib/order.dl's runs_after reads. Positional
  # like conditional_call, and derived here for the same reason: the
  # graphs exist in Argus.Cfg, and the alternative is reading
  # `instruction` and `next` in every solve that asks. A block is named
  # by its first instruction. The flow is one trip's
  # (Cfg.Function.forward_succs/2): a loop's back edge would order two
  # instructions of its body both ways.
  #
  # Only what runs_after can answer is emitted, which on ash is a small
  # part of what the graphs hold:
  #
  # - The kinds rules ask about. A call to a named function, local or
  #   remote, is asked of and read (a cancel, a start, a call toward a
  #   helper or handed a fun: call_site's and fun_handed's
  #   instructions); a receive and a branch are read. A BIF instruction
  #   (`bif`, `gc_bif`), a call through a fun or `apply` and a send have
  #   no row: a rule that asks of one adds its relation here.
  # - The sites an order a call or a receive starts takes part in.
  #   runs_after is asked of those only (order.dl: a branch is read, never
  #   asked of), so a site none runs before, and one nothing runs after,
  #   can be in no answer: a function of branches alone has no row.
  # - The flow contracted to the blocks holding a kept site: runs_after
  #   asks only whether one such block reaches another, so a block
  #   holding none is passed through, and an edge joins a kept site's
  #   block to each block holding one that is the next such on a path
  #   from it. Its closure is the graph's, restricted to those blocks.
  @ordered_sites [
    local_call: "call",
    remote_call: "call",
    recv_start: "receive",
    branch: "branch"
  ]

  defp derive_block_order(base_facts, cfgs) do
    placed =
      for {relation, kind} <- @ordered_sites,
          [id | _] <- Map.get(base_facts, relation, []),
          {:ok, %InstrId{func: name, arity: arity, idx: idx} = site} <- [InstrId.parse(id)],
          fun = Map.get(cfgs, {name, arity}),
          fun != nil,
          block = Cfg.Function.block_at(fun, idx),
          block != nil,
          do: {site, kind, fun, block}

    kept =
      placed
      |> Enum.group_by(fn {site, _, _, _} -> InstrId.fa(site) end)
      |> Enum.map(fn {_fa, held} -> ordered_from_starts(held) end)
      |> Enum.reject(&(&1 == []))

    sites =
      for held <- kept,
          {site, kind, _fun, block} <- held,
          do: [InstrId.format(site), kind, block_name(site, block), Integer.to_string(site.idx)]

    flows =
      for [{site, _kind, fun, _block} | _] = held <- kept,
          holding = Map.new(held, fn {_, _, _, block} -> {block.id, true} end),
          from <- Map.keys(holding),
          to <- next_holding(fun, holding, Map.fetch!(fun.blocks, from)),
          do: [
            block_name(site, Map.fetch!(fun.blocks, from)),
            block_name(site, Map.fetch!(fun.blocks, to))
          ]

    %{}
    |> put_rows(:site_block, sites)
    |> put_rows(:block_flow, flows)
  end

  # The kinds runs_after is asked of: the instructions an order starts at.
  @starts ["call", "receive"]

  # The sites of one function that take part in an order a start (a call
  # or a receive) begins: each a start runs before (earlier in its block,
  # or in a block the flow reaches it from), and each start a site runs
  # after.
  defp ordered_from_starts([{_, _, fun, _} | _] = held) do
    starts = for {site, kind, _fun, block} <- held, kind in @starts, do: {block.id, site.idx}

    first_start =
      Enum.reduce(starts, %{}, fn {b, i}, acc -> Map.update(acc, b, i, &min(&1, i)) end)

    last_site =
      Enum.reduce(held, %{}, fn {s, _, _, b}, acc ->
        Map.update(acc, b.id, s.idx, &max(&1, s.idx))
      end)

    reached = reached_from(fun, Map.keys(first_start))
    holding = Map.new(held, fn {_, _, _, block} -> {block.id, true} end)

    after_start? = fn {site, _kind, _fun, block} ->
      Map.has_key?(reached, block.id) or Map.get(first_start, block.id, site.idx) < site.idx
    end

    before_site? = fn {site, kind, _fun, block} ->
      kind in @starts and
        (site.idx < Map.fetch!(last_site, block.id) or next_holding(fun, holding, block) != [])
    end

    Enum.filter(held, &(after_start?.(&1) or before_site?.(&1)))
  end

  # The blocks one trip's flow reaches from any of `from`, by one edge or
  # more, as a map of block id to true (a plain map, as Cfg.Function's own
  # walks keep theirs: MapSet is opaque to dialyzer through these clauses).
  defp reached_from(fun, from) do
    succs = Enum.flat_map(from, &Cfg.Function.forward_succs(fun, Map.fetch!(fun.blocks, &1)))
    reach(fun, succs, %{})
  end

  defp reach(_fun, [], seen), do: seen

  defp reach(fun, [id | rest], seen) do
    if Map.has_key?(seen, id) do
      reach(fun, rest, seen)
    else
      succs = Cfg.Function.forward_succs(fun, Map.fetch!(fun.blocks, id))
      reach(fun, succs ++ rest, Map.put(seen, id, true))
    end
  end

  # The blocks of `holding` one trip's flow reaches from `block` through
  # blocks outside it: the first of `holding` on each path.
  defp next_holding(fun, holding, block),
    do: next_holding(fun, holding, Cfg.Function.forward_succs(fun, block), %{}, [])

  defp next_holding(_fun, _holding, [], _seen, found), do: found

  defp next_holding(fun, holding, [id | rest], seen, found) do
    cond do
      Map.has_key?(seen, id) ->
        next_holding(fun, holding, rest, seen, found)

      Map.has_key?(holding, id) ->
        next_holding(fun, holding, rest, Map.put(seen, id, true), [id | found])

      true ->
        succs = Cfg.Function.forward_succs(fun, Map.fetch!(fun.blocks, id))
        next_holding(fun, holding, succs ++ rest, Map.put(seen, id, true), found)
    end
  end

  # A block's name: the ID of its first instruction, in the function of
  # `site`.
  defp block_name(%InstrId{} = site, %Cfg.Block{range: {first, _last}}),
    do: InstrId.format(%{site | idx: first})

  defp put_rows(facts, _relation, []), do: facts

  defp put_rows(facts, relation, rows),
    do: Map.put(facts, relation, rows |> Enum.uniq() |> Enum.sort())

  # The blocks ending in a tail call that raises (`erlang:error/1`,
  # `exit/1`, `throw/1`, `raise/3`): the compiler's badmap and a dot
  # access's error side end so, and a path there completes nothing
  # (review 2: a `s.interval` before a send_after made it conditional).
  @raising_bifs ~w(error exit throw raise nif_error)

  defp raising_tail_blocks(base_facts, cfgs) do
    for [id, _func, ":erlang", name, _arity] <- Map.get(base_facts, :remote_call, []),
        name in @raising_bifs,
        {:ok, %InstrId{func: fname, arity: arity, idx: idx}} <- [InstrId.parse(id)],
        fun = Map.get(cfgs, {fname, arity}),
        fun != nil,
        block = Cfg.Function.block_at(fun, idx),
        block != nil,
        block.terminator == :tail_call,
        elem(block.range, 1) == idx,
        reduce: %{} do
      acc -> Map.update(acc, {fname, arity}, MapSet.new([block.id]), &MapSet.put(&1, block.id))
    end
  end

  defp conditional_blocks(fun, raising) do
    case Cfg.Function.completing_blocks(fun, raising) do
      nil ->
        fun |> Cfg.Function.control_deps() |> Map.keys() |> MapSet.new()

      always ->
        for {id, _block} <- fun.blocks, not MapSet.member?(always, id), into: MapSet.new(), do: id
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
