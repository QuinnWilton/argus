defmodule Argus.Graph.Pack do
  @moduledoc """
  A module's facts as the query graph keeps them: text, in one pack per
  module in the blob store (`Roux.Blob`), found again through a
  verifying trace.

  ## Packs

  A module's *pack* holds its rows from every producer (`Argus.Pipeline`'s
  `:base` and each extractor), apart: for each producer, in producer
  order, and for each relation it has rows for, the bytes of its lines
  as a `.facts` file holds them (`Argus.Pipeline.Writer.encode/2`). A
  relation's chunk of the module is its producers' bytes joined in that
  order (`chunk/2`), and a relation's file is its modules' chunks joined
  (`Argus.Graph.Relations`). The pack is one blob: a relation's file is
  assembled with one read per module.

  ## The trace

  A module's pack is found again by a trace (`Roux.Blob.Trace`) named by
  the beam's digest and the options that shape its rows, which records
  for each producer the digest of the code it ran (`Argus.Graph.Code`'s
  `producer_code`) and what it read that its code does not name: each schema entry
  it read, and — for a producer that reads specs from the code path —
  each module whose specs it read (by its name, a string: a trace is
  read back only when every atom in it exists, and a callee outside
  the program is one a fresh VM has not made), with what each was. A producer's rows
  in the pack are used while its code digest is the one running and
  every one of those still is what it was, each observed through its
  query (`Argus.Graph.Reads`), so the module's `module_facts` depends on
  exactly them. Only the producers whose rows no longer hold run, over
  the module's kept base when there is one, and a new pack takes their
  rows beside the others': an extractor edit re-runs that extractor, and
  only it, on each module. A warm run reads the trace and nothing else:
  the trace holds each relation's chunk digest.

  A base is kept (`Argus.Pipeline.Base`) by the run that extracted
  extractors alone and found none: the first such run computes and keeps
  it, every later one reads it back. A run that extracts the base's own
  rows (cold, or after the base's code moved) keeps none, as the batch
  store does: it would cost that run a tenth more for a run that may not
  come.

  A module that was lost (it outlived the per-module timeout, or its
  worker exited) keeps no trace: its rows depend on the machine's load.

  ## Telemetry

  `[:argus, :graph, :extract]` is emitted each time producers run over a
  module: measurements `%{producers: count}`, metadata `%{module:,
  producers:, kept_base:}` (whether they ran over a kept base).
  """

  alias Argus.Graph.Reads
  alias Argus.Pipeline
  alias Roux.Blob
  alias Roux.Blob.Trace
  alias Roux.Runtime

  # Moves every trace and every pack: bump it when what either holds, or
  # how one is named, changes.
  @format "argus-pack-3"

  # How many of a module's traces a lookup weighs, most recent first.
  @candidates 3

  @typedoc """
  A module's facts: its name, its pack's digest, each relation's chunk
  digest (the SHA-256 of its bytes), and whether it was lost.
  """
  @type t :: %{
          module: module() | nil,
          pack: Blob.digest(),
          relations: %{atom() => binary()},
          lost: boolean()
        }

  @typedoc "A pack: each producer's rows, by relation, in producer order."
  @type pack :: [{Pipeline.producer(), %{atom() => binary()}}]

  @doc """
  The facts of the beam `input` (a path or the bytes, `hash` its
  digest, `module` its name or nil) for the producers of `codes` (each
  producer and the digest of the code it runs, `:base` first), found or
  extracted: `{:ok, facts}` or the pipeline's error for a beam it cannot
  read. Called in the body of `module_facts`, whose edges the
  observations and the recorded reads become.
  """
  @spec extract(Roux.Database.t(), Path.t() | binary(), String.t(), module() | nil, %{
          Pipeline.producer() => term()
        }) :: {:ok, t()} | {:error, term()}
  def extract(db, input, hash, module, codes) do
    store = db.blob
    producers = [:base | codes |> Map.keys() |> List.delete(:base) |> Enum.sort()]
    # A beam that cannot be read names its rows by its path.
    identity = if module, do: {:beam, hash}, else: {:beam, hash, path_of(input)}
    name = {:argus_module, @format, identity, shaping()}
    observe = memo_observe(db)

    {kept, observe} = best(store, name, producers, codes, observe)

    case kept do
      %{missing: [], trace: trace} ->
        _ = Blob.touch(trace.path)
        Runtime.hold([trace.value.pack | base_digests(trace.value)])
        {:ok, facts(module, trace.value, false)}

      kept ->
        rebuild(db, name, input, module, producers, codes, kept, observe)
    end
  end

  defp path_of(input) when is_binary(input) do
    if match?(<<"FOR1", _::binary>>, input), do: "(beam data)", else: input
  end

  # The options that shape a producer's rows: which relations are
  # written, and imprecision traced (for the coverage analysis; it only
  # adds rows to a relation of its own). The in-process relations
  # (`Argus.Schema.in_process_only/0`) no program of argus's reads, and
  # they are most of the rows.
  defp shaping, do: {:except, Enum.sort(Argus.Schema.in_process_only()), :trace_imprecision}

  # Observing a read: through its query, each at most once per lookup.
  defp memo_observe(db) do
    %{db: db, seen: %{}}
  end

  defp observe(%{db: db, seen: seen} = observer, dep) do
    case seen do
      %{^dep => value} ->
        {value, observer}

      %{} ->
        value =
          case dep do
            {:schema, read} -> Reads.schema_entry(db, read)
            {:installed, name} -> Reads.installed_specs(db, String.to_atom(name))
          end

        {value, %{observer | seen: Map.put(seen, dep, value)}}
    end
  end

  defp holds?(observer, observed) do
    Enum.reduce_while(observed, {true, observer}, fn {dep, value}, {true, observer} ->
      {now, observer} = observe(observer, dep)
      if now === value, do: {:cont, {true, observer}}, else: {:halt, {false, observer}}
    end)
  end

  # The trace that keeps the most producers' rows, and which producers it
  # does not: `%{trace: trace | nil, missing: producers, base: kept}`.
  defp best(store, name, producers, codes, observer) do
    store
    |> Trace.fetch(name)
    |> Enum.take(@candidates)
    |> Enum.filter(&Blob.member?(store, &1.value.pack))
    |> Enum.reduce_while({%{trace: nil, missing: producers, base: nil}, observer}, fn trace,
                                                                                      {best,
                                                                                       observer} ->
      {missing, observer} = stale(trace.value, producers, codes, observer)
      candidate = %{trace: trace, missing: missing, base: nil}
      best = if rank(candidate) < rank(best), do: candidate, else: best
      if missing == [], do: {:halt, {best, observer}}, else: {:cont, {best, observer}}
    end)
  end

  # Fewer producers to run first; between two that leave the same
  # number, the one that kept a base the producers can run over.
  defp rank(%{trace: nil, missing: missing}), do: {length(missing), 1}

  defp rank(%{trace: trace, missing: missing}),
    do: {length(missing), if(Map.get(trace.value, :base), do: 0, else: 1)}

  # The producers whose rows in the trace's pack no longer hold.
  defp stale(value, producers, codes, observer) do
    Enum.reduce(producers, {[], observer}, fn producer, {missing, observer} ->
      case Map.fetch(value.producers, producer) do
        {:ok, %{code: code, observed: observed}} when code == :erlang.map_get(producer, codes) ->
          case holds?(observer, observed) do
            {true, observer} -> {missing, observer}
            {false, observer} -> {missing ++ [producer], observer}
          end

        _ ->
          {missing ++ [producer], observer}
      end
    end)
  end

  # What names a trace among a module's others: the code it was made by
  # and what its producers observed. Two VMs whose code paths differ
  # (a test VM and its peer) observe other specs of one callee: each
  # keeps a trace of its own beside the other's, and finds it again,
  # rather than each replacing the other's in turn.
  defp trace_deps(codes, value) do
    observed =
      for {producer, %{observed: observed}} <- Enum.sort(value.producers),
          do: {producer, observed}

    base = if value.base, do: value.base.observed, else: []

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({observed, base}, [:deterministic]))

    [{:codes, codes}, {:observed, Base.encode16(digest, case: :lower)}]
  end

  defp base_digests(%{base: %{digest: digest}}), do: [digest]
  defp base_digests(_value), do: []

  # The missing producers extracted together over the module's kept
  # base when there is one, and a new pack of their rows and the kept
  # ones'.
  defp rebuild(db, name, input, module, producers, codes, kept, observer) do
    store = db.blob
    old = if kept.trace, do: kept.trace.value
    missing = kept.missing
    base_missing? = :base in missing

    {base, observer} =
      if base_missing?, do: {nil, observer}, else: kept_base(store, old, codes, observer)

    # Where the specs are read from: the precise edges are each read's
    # `installed_specs`, which reads the source itself.
    source = Runtime.untracked(fn -> Runtime.input(db, :specs_source, :all, default: nil) end)

    opts = [
      specs_source: source,
      producers: missing,
      base: base && base.binary,
      keep_base: not base_missing? and base == nil,
      relations: {:except, Argus.Schema.in_process_only()},
      trace_imprecision: true
    ]

    opts =
      case Application.get_env(:panoptes, :extraction_timeout) do
        nil -> opts
        ms -> Keyword.put(opts, :timeout, ms)
      end

    :telemetry.execute([:argus, :graph, :extract], %{producers: length(missing)}, %{
      module: module,
      producers: missing,
      kept_base: base != nil
    })

    with {:ok, extraction} <- Pipeline.extract_module(input, opts),
         {:ok, old_pack} <- old_pack(store, old, missing) do
      lost? = extraction.status == :lost
      base_reads = if base, do: base.reads, else: Map.get(extraction.reads, :base, [])
      Reads.record_installed(extraction.installed)
      Argus.Schema.Reads.record_all(Enum.concat(Map.values(extraction.reads)) ++ base_reads)

      pack =
        if lost?,
          do: [{:base, Map.fetch!(extraction.facts, :base)}],
          else:
            for(p <- producers, do: {p, Map.get(extraction.facts, p) || Map.fetch!(old_pack, p)})

      {:ok, digest} = Blob.put_term(store, pack)
      relations = relation_digests(pack)
      {base_entry, observer} = base_entry(store, base, extraction, base_reads, codes, observer)

      unless lost? do
        {entries, _observer} =
          producer_entries(old, producers, missing, codes, extraction, base_reads, observer)

        value = %{pack: digest, relations: relations, producers: entries, base: base_entry}
        _ = Trace.put(store, name, trace_deps(codes, value), value)
      end

      Runtime.hold([digest | base_digests(%{base: base_entry})])
      {:ok, facts(module, %{pack: digest, relations: relations}, lost?)}
    end
  end

  # What each producer's rows now rest on: the kept ones' as the trace
  # recorded it, the extracted ones' as observed now.
  defp producer_entries(old, producers, missing, codes, extraction, base_reads, observer) do
    Enum.reduce(producers, {%{}, observer}, fn producer, {acc, observer} ->
      if producer in missing do
        schema = Map.get(extraction.reads, producer, [])
        schema = if producer == :base, do: schema, else: :ordsets.union(schema, base_reads)

        installed =
          if Argus.Cache.Code.reads_installed?(producer), do: extraction.installed, else: []

        # A callee by its name: a fresh VM decodes a trace only when
        # every atom in it exists (`Roux.Blob.decode/1`), and a callee
        # outside the program is an atom nothing there has made yet.
        deps =
          Enum.map(schema, &{:schema, &1}) ++
            Enum.map(Enum.sort(installed), &{:installed, Atom.to_string(&1)})

        {observed, observer} =
          Enum.map_reduce(deps, observer, fn dep, observer ->
            {value, observer} = observe(observer, dep)
            {{dep, value}, observer}
          end)

        {Map.put(acc, producer, %{code: codes[producer], observed: observed}), observer}
      else
        {Map.put(acc, producer, Map.fetch!(old.producers, producer)), observer}
      end
    end)
  end

  # The base the extractors ran over, kept for the next run: the one read
  # back, or the one this run computed; none when the base's own rows
  # were extracted.
  defp base_entry(_store, %{entry: entry}, _extraction, _reads, _codes, observer),
    do: {entry, observer}

  defp base_entry(store, nil, %{base: binary}, reads, codes, observer) when is_binary(binary) do
    {:ok, digest} = Blob.put(store, binary)

    {observed, observer} =
      Enum.map_reduce(reads, observer, fn read, observer ->
        {value, observer} = observe(observer, {:schema, read})
        {{{:schema, read}, value}, observer}
      end)

    {%{digest: digest, code: codes[:base], reads: reads, observed: observed}, observer}
  end

  defp base_entry(_store, nil, _extraction, _reads, _codes, observer), do: {nil, observer}

  # The base a trace kept, while the base's code and what computing it
  # read hold, and the store still has it.
  defp kept_base(store, %{base: %{} = entry}, codes, observer) do
    with true <- entry.code == codes[:base],
         {true, observer} <- holds?(observer, entry.observed),
         {:ok, binary} <- Blob.get(store, entry.digest) do
      {%{binary: binary, reads: entry.reads, entry: entry}, observer}
    else
      {false, observer} -> {nil, observer}
      _ -> {nil, observer}
    end
  end

  defp kept_base(_store, _old, _codes, observer), do: {nil, observer}

  # The old pack's rows, by producer, when some of them are kept.
  defp old_pack(_store, nil, _missing), do: {:ok, %{}}

  defp old_pack(store, old, _missing) do
    case read(store, old.pack) do
      {:ok, pack} -> {:ok, Map.new(pack)}
      :miss -> {:error, {:pack_missing, old.pack}}
    end
  end

  defp relation_digests(pack) do
    pack
    |> Enum.flat_map(fn {_producer, relations} -> Map.keys(relations) end)
    |> Enum.uniq()
    |> Map.new(fn relation -> {relation, :crypto.hash(:sha256, chunk(pack, relation))} end)
  end

  defp facts(module, value, lost?),
    do: %{module: module, pack: value.pack, relations: value.relations, lost: lost?}

  @doc """
  A relation's chunk of a pack: its producers' bytes, joined in producer
  order; empty when the module has none.
  """
  @spec chunk(pack(), atom()) :: binary()
  def chunk(pack, relation) do
    IO.iodata_to_binary(for {_producer, relations} <- pack, do: Map.get(relations, relation, ""))
  end

  @doc "A pack, read back: `{:ok, pack}` or `:miss`."
  @spec read(Blob.t(), Blob.digest()) :: {:ok, pack()} | :miss
  def read(store, digest), do: Blob.get_term(store, digest)
end
