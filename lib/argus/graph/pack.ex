defmodule Argus.Graph.Pack do
  @moduledoc """
  A module's facts as the query graph keeps them: text, one segment per
  producer in the blob store (`Roux.Blob`), found again through one
  verifying trace per module.

  ## Segments and packs

  A module's rows from one producer (`Argus.Pipeline`'s `:base` and each
  extractor) are that producer's *segment*: for each relation it has
  rows for, the bytes of its lines as a `.facts` file holds them
  (`Argus.Pipeline.Writer.encode/2`), in one blob. A producer with no
  rows for the module has none. The module's *pack* is their index:
  each producer that has a segment, in producer order, with the
  segment's digest and the relations it holds. A relation's chunk of the
  module is its producers' bytes joined in that order (`chunks/4`), and a
  relation's file is its modules' chunks joined (`Argus.Graph.Relations`).

  Each relation of the module is named by a digest of its chunk: the
  SHA-256 of its bytes when one producer has rows for it, as all but a
  few relations have, else of its producers' digests, in producer
  order. So a producer that runs again writes its own segment alone,
  and the module's digests are made without reading any other.

  ## The trace

  A module's segments are found again by its trace (`Roux.Blob.Trace`),
  named by the beam's digest and the options that shape its rows. For
  each producer it keeps the *variants* its rows were made under, the
  most recently made first: each the digest of the code it ran
  (`Argus.Graph.Code`'s `producer_code`), what it read that its code
  does not name — each schema entry it read, and, for a producer that
  reads specs from the code path, each module whose specs it read (by
  its name, a string: a trace is read back only when every atom in it
  exists, and a callee outside the program is one a fresh VM has not
  made), with what each was — and its segment. A producer's rows are a
  variant's while that variant's code is the one running and every one
  of those still is what it was, each observed through its query
  (`Argus.Graph.Reads`), so the module's `module_facts` depends on
  exactly them.

  Only the producers no variant holds for run, over the module's kept
  base, and the trace takes their new variants at its head: an
  extractor edit re-runs that extractor, and only it, on each module,
  reading and writing its own segment; an edit undone finds the variant
  it had before. Two VMs whose code paths differ (a test VM and its
  peer) observe other specs of one callee, and each finds its own
  variant beside the other's.

  The trace also names the pack of each producer's newest variant, and
  the module's relation digests with it: a lookup that finds them all
  holding reads the trace, one small file, and nothing else. The blobs
  a trace names stay in the store while it is used (`Roux.Blob.gc/2`).

  ## Kept bases

  A module's base (`Argus.Pipeline.Base`) is kept beside its trace by
  every run that computes one — the cold one too, so the first
  extractor edit already runs over it — and read back while the base's
  code and what computing it read still are what they were.

  A module that was lost (it outlived the per-module timeout, or its
  worker exited) keeps no trace: its rows depend on the machine's load.

  ## A blob the store lost

  A lookup trusts the blobs its trace names without a look, and a kept
  entry the blobs its value names: a warm run reads no segment it does
  not assemble a relation from. One may still be gone (collected while
  a run used it, or removed by hand). Reading a module's chunks through
  the graph (`read_chunks/6`) then extracts the module again, as a cold
  run does, and puts the blobs back under the digests the pack names —
  the same beam under the same code makes the same bytes — so the run
  goes on and every later one finds them (`restore/3`).

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
  @format "argus-pack-5"

  # How many variants a trace keeps of each producer's rows, and of the
  # module's base, the most recently made first: an edit or two undone,
  # and another VM's code path.
  @variants 4
  @bases 2

  # A relation more than one producer has rows for is named by its
  # producers' digests, under a prefix no single chunk's digest is
  # taken over.
  @joined "argus-joined-chunk\n"

  @typedoc """
  A module's facts: its name, its pack's digest, each relation's chunk
  digest, and whether it was lost.
  """
  @type t :: %{
          module: module() | nil,
          pack: Blob.digest(),
          relations: %{atom() => binary()},
          lost: boolean()
        }

  @typedoc """
  A pack: each producer with a segment, in producer order, with its
  segment's digest and the relations the segment holds.
  """
  @type pack :: [{Pipeline.producer(), Blob.digest(), [atom()]}]

  @typedoc """
  Which of a module's relations a pack holds: `:extracted`, every one
  but the relations only the in-process passes read
  (`Argus.Schema.in_process_only/0`), from every producer; or
  `:in_process`, those alone, from the base (what a program of the
  caller's own that reads them solves over).
  """
  @type kind :: :extracted | :in_process

  @doc """
  The facts of the beam `input` (a path or the bytes, `hash` its
  digest, `module` its name or nil) for the producers of `codes` (each
  producer and the digest of the code it runs), found or extracted:
  `{:ok, facts}` or the pipeline's error for a beam it cannot read.
  Called in the body of a query, whose edges the observations and the
  recorded reads become. `kind` (`t:kind/0`) says which relations.
  """
  @spec extract(
          Roux.Database.t(),
          Path.t() | binary(),
          String.t(),
          module() | nil,
          %{Pipeline.producer() => term()},
          kind()
        ) :: {:ok, t()} | {:error, term()}
  def extract(db, input, hash, module, codes, kind \\ :extracted) do
    store = db.blob
    producers = producers(kind, codes)
    # A beam that cannot be read names its rows by its path.
    identity = if module, do: {:beam, hash}, else: {:beam, hash, path_of(input)}
    name = {:argus_module, @format, identity, shaping(kind)}
    trace = fetch(store, name)
    {chosen, missing, observer} = choose(trace, producers, codes, memo_observe(db))

    case {missing, trace && trace.value.current} do
      {[], %{} = current} when chosen == current.chosen ->
        used(trace)
        hold(producers, chosen, head_base(trace), current.pack)
        {:ok, facts(module, current, false)}

      {[], _current} ->
        used(trace)
        {current, _chosen} = pack(store, producers, chosen)
        hold(producers, chosen, head_base(trace), current.pack)
        {:ok, facts(module, current, false)}

      {_missing, _current} ->
        run = %{db: db, name: name, input: input, module: module, kind: kind}
        rebuild(run, producers, codes, trace, chosen, missing, observer)
    end
  end

  defp producers(:extracted, codes),
    do: [:base | codes |> Map.keys() |> List.delete(:base) |> Enum.sort()]

  defp producers(:in_process, _codes), do: [:base]

  # The options that shape a producer's rows: which relations are
  # written, and imprecision traced (for the coverage analysis; it only
  # adds rows to a relation of its own). The in-process relations
  # (`Argus.Schema.in_process_only/0`) no program of argus's reads, and
  # they are most of the rows: packs of their own hold them.
  defp shaping(:extracted),
    do: {:except, Enum.sort(Argus.Schema.in_process_only()), :trace_imprecision}

  defp shaping(:in_process), do: {:only, Enum.sort(Argus.Schema.in_process_only())}

  defp relations(:extracted), do: {:except, Argus.Schema.in_process_only()}
  defp relations(:in_process), do: Argus.Schema.in_process_only()

  defp path_of(input) when is_binary(input) do
    if match?(<<"FOR1", _::binary>>, input), do: "(beam data)", else: input
  end

  # ── The trace ───────────────────────────────────────────────────────

  # The module's trace, its value expanded, or nil.
  defp fetch(store, name) do
    case Trace.fetch(store, name, limit: 1) do
      [trace] -> %{trace | value: expand(trace.value)}
      [] -> nil
    end
  end

  # A trace found and used, marked so (its modification time) for the
  # store's recency, as `Roux.Blob.Trace.find/4` marks one: at most once
  # a refresh interval, so a warm run writes nothing.
  defp used(%{path: path, mtime: mtime, refresh: refresh}) do
    if System.os_time(:second) - mtime >= refresh, do: _ = Blob.touch(path)
    :ok
  end

  # Each producer's variant that holds, and the producers none does: a
  # variant holds when its code is the one running and every
  # observation is what it was. Its segment is in the store while the
  # trace is used: the store's collection keeps what a trace used
  # within its keep period names.
  defp choose(trace, producers, codes, observer) do
    variants = if trace, do: trace.value.variants, else: %{}

    Enum.reduce(producers, {%{}, [], observer}, fn producer, {chosen, missing, observer} ->
      code = Map.fetch!(codes, producer)

      case holding(Map.get(variants, producer, []), code, observer) do
        {nil, observer} -> {chosen, missing ++ [producer], observer}
        {variant, observer} -> {Map.put(chosen, producer, variant), missing, observer}
      end
    end)
  end

  defp holding([], _code, observer), do: {nil, observer}

  defp holding([variant | rest], code, observer) do
    with true <- variant.code == code,
         {true, observer} <- holds?(observer, variant.observed) do
      {variant, observer}
    else
      {false, observer} -> holding(rest, code, observer)
      false -> holding(rest, code, observer)
    end
  end

  # Observing a read: through its query, each at most once per lookup.
  defp memo_observe(db), do: %{db: db, seen: %{}}

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

  # Whether every observation, a `{dep, value}` pair, still is what it was.
  defp holds?(observer, observed) do
    Enum.reduce_while(observed, {true, observer}, fn {dep, value}, {true, observer} ->
      {now, observer} = observe(observer, dep)
      if now === value, do: {:cont, {true, observer}}, else: {:halt, {false, observer}}
    end)
  end

  # A trace's value as it is kept: every producer observes much the same
  # reads (the base's, which each extractor's rows rest on, and its own),
  # so the observations are kept once, in a table, and each variant's
  # (and each kept base's) as indexes into it. `expand/1` gives the
  # value back.
  defp compact(value) do
    table =
      value.variants
      |> Enum.flat_map(fn {_producer, variants} -> Enum.flat_map(variants, & &1.observed) end)
      |> Kernel.++(Enum.flat_map(value.bases, & &1.observed))
      |> Enum.uniq()
      |> Enum.sort()

    index = table |> Enum.with_index() |> Map.new()

    indexes = fn entry ->
      %{entry | observed: Enum.map(entry.observed, &Map.fetch!(index, &1))}
    end

    %{
      variants: Map.new(value.variants, fn {p, variants} -> {p, Enum.map(variants, indexes)} end),
      bases: Enum.map(value.bases, indexes),
      current: value.current,
      observations: List.to_tuple(table)
    }
  end

  defp expand(%{observations: table} = value) do
    pairs = fn entry -> %{entry | observed: Enum.map(entry.observed, &elem(table, &1))} end

    variants = Map.new(value.variants, fn {p, variants} -> {p, Enum.map(variants, pairs)} end)

    # The pack it names is the newest variants': the choice a lookup
    # that finds them all holding makes.
    current =
      value.current &&
        Map.put(value.current, :chosen, Map.new(variants, fn {p, [head | _]} -> {p, head} end))

    %{variants: variants, bases: Enum.map(value.bases, pairs), current: current}
  end

  defp head_base(%{value: %{bases: [base | _]}}), do: base
  defp head_base(_trace), do: nil

  # ── Running the producers no variant holds for ──────────────────────

  # The missing producers extracted together, over the module's kept
  # base when there is one, each writing its segment; the trace takes
  # their variants at its head.
  defp rebuild(run, producers, codes, trace, chosen, missing, observer) do
    store = run.db.blob
    base_missing? = :base in missing

    {base, observer} =
      if base_missing? or run.kind == :in_process,
        do: {nil, observer},
        else: kept_base(store, trace, codes, observer)

    opts =
      extraction_opts(run.db, run.kind,
        producers: missing,
        base: base && base.binary,
        keep_base: base == nil and run.kind == :extracted
      )

    :telemetry.execute([:argus, :graph, :extract], %{producers: length(missing)}, %{
      module: run.module,
      producers: missing,
      kept_base: base != nil
    })

    with {:ok, extraction} <- Pipeline.extract_module(run.input, opts) do
      base_reads = if base, do: base.reads, else: Map.get(extraction.reads, :base, [])
      Reads.record_installed(extraction.installed)
      Argus.Schema.Reads.record_all(Enum.concat(Map.values(extraction.reads)) ++ base_reads)

      if extraction.status == :lost do
        # The base's error row alone, whatever else was asked for.
        {:ok, variant} = variant(store, :base, codes, extraction.facts.base, [])
        {current, chosen} = pack(store, [:base], %{base: variant})
        hold([:base], chosen, nil, current.pack)
        {:ok, facts(run.module, current, true)}
      else
        {made, observer} =
          Enum.map_reduce(missing, observer, fn producer, observer ->
            observed_variant(store, producer, codes, extraction, base_reads, observer)
          end)

        chosen = Map.merge(chosen, Map.new(made))
        {base_entry, _observer} = base_entry(store, base, extraction, base_reads, codes, observer)
        {current, chosen} = pack(store, producers, chosen)
        old = if trace, do: trace.value, else: %{variants: %{}, bases: []}
        value = next_value(old, producers, chosen, base_entry, current)
        _ = Trace.put(store, run.name, [], compact(value), keep: 1)
        hold(producers, chosen, base_entry, current.pack)
        {:ok, facts(run.module, current, false)}
      end
    end
  end

  # What `Argus.Pipeline.extract_module/2` is asked for a module of
  # `kind`: `opts`, and the relations the kind holds, imprecision traced,
  # the specs read from where the graph's input says (the precise edges
  # are each read's `installed_specs`, which reads the source itself),
  # and the configured per-module timeout.
  defp extraction_opts(db, kind, opts) do
    source = Runtime.untracked(fn -> Runtime.input(db, :specs_source, :all, default: nil) end)
    opts = [specs_source: source, relations: relations(kind), trace_imprecision: true] ++ opts

    case Application.get_env(:argus_beam, :extraction_timeout) do
      nil -> opts
      ms -> Keyword.put(opts, :timeout, ms)
    end
  end

  # A producer's new variant: its segment written, and what its rows now
  # rest on, observed.
  defp observed_variant(store, producer, codes, extraction, base_reads, observer) do
    schema = Map.get(extraction.reads, producer, [])
    schema = if producer == :base, do: schema, else: :ordsets.union(schema, base_reads)

    installed =
      if Argus.Graph.Code.reads_installed?(producer), do: extraction.installed, else: []

    # A callee by its name: a fresh VM decodes a trace only when every
    # atom in it exists (`Roux.Blob.decode/1`), and a callee outside the
    # program is an atom nothing there has made yet.
    deps =
      Enum.map(schema, &{:schema, &1}) ++
        Enum.map(Enum.sort(installed), &{:installed, Atom.to_string(&1)})

    {observed, observer} =
      Enum.map_reduce(deps, observer, fn dep, observer ->
        {value, observer} = observe(observer, dep)
        {{dep, value}, observer}
      end)

    {:ok, variant} =
      variant(store, producer, codes, Map.get(extraction.facts, producer, %{}), observed)

    {{producer, variant}, observer}
  end

  defp variant(store, producer, codes, encoded, observed) do
    relations = Map.new(encoded, fn {relation, bytes} -> {relation, sha256(bytes)} end)

    segment =
      case map_size(encoded) do
        0 -> {:ok, nil}
        _ -> Blob.put_term(store, encoded)
      end

    with {:ok, segment} <- segment do
      {:ok,
       %{
         code: Map.fetch!(codes, producer),
         observed: observed,
         segment: segment,
         relations: relations
       }}
    end
  end

  # The trace's next value: each producer's chosen variant at its head,
  # before the ones it had, but a variant of the same code and
  # observations (a segment written again), up to `@variants`; and the
  # base the extractors ran over, or the one this run computed, likewise.
  defp next_value(old, producers, chosen, base_entry, current) do
    variants =
      Map.new(producers, fn producer ->
        head = Map.fetch!(chosen, producer)
        rest = Enum.reject(Map.get(old.variants, producer, []), &same_variant?(&1, head))
        {producer, Enum.take([head | rest], @variants)}
      end)

    bases =
      case base_entry do
        nil -> old.bases
        entry -> Enum.take([entry | Enum.reject(old.bases, &same_variant?(&1, entry))], @bases)
      end

    %{variants: variants, bases: bases, current: current}
  end

  defp same_variant?(a, b), do: a.code == b.code and a.observed == b.observed

  # The base the extractors ran over, as its trace keeps it: the one read
  # back, or the one this run computed; none when neither.
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

  # The first base the trace kept whose code is the base's now, whose
  # reads still are what they were, and which the store still has.
  defp kept_base(_store, nil, _codes, observer), do: {nil, observer}

  defp kept_base(store, trace, codes, observer) do
    Enum.reduce_while(trace.value.bases, {nil, observer}, fn entry, {nil, observer} ->
      with true <- entry.code == codes[:base],
           {true, observer} <- holds?(observer, entry.observed),
           {:ok, binary} <- Blob.get(store, entry.digest) do
        {:halt, {%{binary: binary, reads: entry.reads, entry: entry}, observer}}
      else
        {false, observer} -> {:cont, {nil, observer}}
        _ -> {:cont, {nil, observer}}
      end
    end)
  end

  # ── The module's facts ──────────────────────────────────────────────

  # The pack of the chosen variants, put into the store (a pack made
  # before is found there), with the module's relation digests.
  defp pack(store, producers, chosen) do
    index =
      for producer <- producers,
          %{segment: segment, relations: relations} = Map.fetch!(chosen, producer),
          segment != nil,
          do: {producer, segment, relations |> Map.keys() |> Enum.sort()}

    {:ok, digest} = Blob.put_term(store, index)
    {%{pack: digest, relations: relation_digests(producers, chosen)}, chosen}
  end

  # The blobs the running query's value names: the pack, its segments
  # and the kept base the next extraction runs over.
  defp hold(producers, chosen, base_entry, pack) do
    segments =
      for producer <- producers,
          %{segment: segment} = Map.fetch!(chosen, producer),
          segment != nil,
          do: segment

    base = if base_entry, do: [base_entry.digest], else: []
    Runtime.hold([pack | segments] ++ base)
  end

  defp facts(module, current, lost?),
    do: %{module: module, pack: current.pack, relations: current.relations, lost: lost?}

  # Each relation's digest: its one producer's, or its producers'
  # joined, in producer order.
  defp relation_digests(producers, chosen) do
    producers
    |> Enum.flat_map(fn producer -> Map.fetch!(chosen, producer).relations |> Enum.to_list() end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn
      {relation, [digest]} -> {relation, digest}
      {relation, digests} -> {relation, sha256([@joined | digests])}
    end)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data)

  @doc """
  The chunks of `relations` in the module whose pack is `pack`: each
  relation's bytes from `producers` (`:all`, the default, for every
  producer's), joined in producer order; a relation the module has no
  rows for from them is left out. Reads the pack and the segments that
  hold one of the relations, each once. `{:missing, digest}` names a
  blob the store no longer has.
  """
  @spec chunks(Blob.t(), Blob.digest(), [atom()], :all | [Pipeline.producer()]) ::
          {:ok, %{atom() => binary()}} | {:missing, Blob.digest()}
  def chunks(store, pack, relations, producers \\ :all) do
    wanted = MapSet.new(relations)

    with {:ok, index} <- get_term(store, pack) do
      index
      |> Enum.filter(fn {producer, _segment, held} ->
        (producers == :all or producer in producers) and
          Enum.any?(held, &MapSet.member?(wanted, &1))
      end)
      |> Enum.reduce_while({:ok, %{}}, fn {_producer, segment, _held}, {:ok, acc} ->
        case get_term(store, segment) do
          {:ok, rows} ->
            acc =
              rows
              |> Map.take(relations)
              |> Enum.reduce(acc, fn {relation, bytes}, acc ->
                Map.update(acc, relation, [bytes], &[bytes | &1])
              end)

            {:cont, {:ok, acc}}

          missing ->
            {:halt, missing}
        end
      end)
      |> case do
        {:ok, acc} ->
          {:ok,
           Map.new(acc, fn {r, parts} -> {r, parts |> Enum.reverse() |> IO.iodata_to_binary()} end)}

        missing ->
          missing
      end
    end
  end

  @doc """
  `chunks/4` of the module `beam_key`, whose facts `query` keeps
  (`:module_facts` or `:module_in_process`) under `pack`, read from
  `db`'s store: when the store no longer has a blob the pack names (a
  segment collected while a trace still named it), the module is
  extracted again (`restore/3`) and the chunks read from what that puts
  back. `{:error, {:facts_lost, beam_key, digest, reason}}` when they
  cannot be.

  Reads the graph without edges: the caller depends on `query`'s entry
  already, and that entry on what made the pack.
  """
  @spec read_chunks(
          Roux.Database.t(),
          :module_facts | :module_in_process,
          term(),
          Blob.digest(),
          [atom()],
          :all | [Pipeline.producer()]
        ) :: {:ok, %{atom() => binary()}} | {:error, term()}
  def read_chunks(db, query, beam_key, pack, relations, producers \\ :all) do
    with {:missing, digest} <- chunks(db.blob, pack, relations, producers) do
      restored =
        with :ok <- restore(db, {query, beam_key}, pack),
             {:missing, digest} <- chunks(db.blob, pack, relations, producers) do
          {:error, {:blob_missing, digest}}
        end

      case restored do
        {:ok, chunks} -> {:ok, chunks}
        {:error, reason} -> {:error, {:facts_lost, beam_key, digest, reason}}
      end
    end
  end

  @doc """
  Puts back the blobs of `pack` the store lost, by extracting the module
  `beam_key` again: every producer `query` keeps rows of, as a cold run
  does, each segment put again and the pack with them. The same beam
  under the same code makes the same bytes (extraction is
  deterministic), so they come back under the digests `pack` names:
  `:ok`; `{:error, {:not_reproduced, made}}` when the extraction made
  another pack, or the extraction's error.

  Emits `[:argus, :graph, :extract]` as any extraction does. Reads the
  graph without edges and records no read of the schema: the entry
  whose value names `pack` depends on what made it already.
  """
  @spec restore(
          Roux.Database.t(),
          {:module_facts | :module_in_process, term()},
          Blob.digest()
        ) :: :ok | {:error, term()}
  def restore(db, {query, beam_key}, pack) do
    {result, _reads} =
      Argus.Schema.Reads.isolated(fn ->
        Runtime.untracked(fn ->
          case Runtime.query(db, :module_beam, beam_key) do
            {:ok, beam} -> restore(db, query, beam_key, beam, pack)
            :external -> {:error, {:external, beam_key}}
          end
        end)
      end)

    result
  end

  defp restore(db, query, beam_key, beam, pack) do
    store = db.blob
    module = Runtime.query(db, :module_name, beam_key)

    {kind, codes} =
      case query do
        :module_facts -> {:extracted, Runtime.query(db, :producer_code, :all)}
        :module_in_process -> {:in_process, %{base: Runtime.query(db, :base_code, :all)}}
      end

    producers = producers(kind, codes)

    :telemetry.execute([:argus, :graph, :extract], %{producers: length(producers)}, %{
      module: module,
      producers: producers,
      kept_base: false
    })

    opts = extraction_opts(db, kind, producers: producers, keep_base: false)

    case Pipeline.extract_module(Argus.Graph.Frontend.read(beam), opts) do
      {:ok, %{status: :ok} = extraction} ->
        chosen =
          Map.new(producers, fn producer ->
            encoded = Map.get(extraction.facts, producer, %{})
            {:ok, variant} = variant(store, producer, codes, encoded, [])
            {producer, variant}
          end)

        case pack(store, producers, chosen) do
          {%{pack: ^pack}, _chosen} -> :ok
          {%{pack: made}, _chosen} -> {:error, {:not_reproduced, made}}
        end

      {:ok, %{status: :lost}} ->
        {:error, :lost}

      {:error, _} = error ->
        error
    end
  end

  defp get_term(store, digest) do
    case Blob.get_term(store, digest) do
      {:ok, term} -> {:ok, term}
      :miss -> {:missing, digest}
    end
  end
end
